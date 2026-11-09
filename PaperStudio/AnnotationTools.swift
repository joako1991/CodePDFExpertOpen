// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

@MainActor
extension PDFWorkspace {
    func groupedAnnotations(_ annotation: PDFAnnotation) -> [PDFAnnotation] {
        guard let page = annotation.page, let name = annotation.value(forAnnotationKey:.name) as? String,
              name.hasPrefix("PaperStudio-") else { return [annotation] }
        let group = name.split(separator:"-").dropLast().joined(separator:"-")
        return page.annotations.filter {
            guard let name = $0.value(forAnnotationKey:.name) as? String else { return false }
            return name.split(separator:"-").dropLast().joined(separator:"-") == group
        }
    }
    func addShape(on page: PDFPage, from first: CGPoint, to last: CGPoint, tool: CanvasTool) {
        guard tool.isShape, page.document === document, hypot(last.x-first.x, last.y-first.y) >= 2 else { return }
        var box = CGRect(x: min(first.x,last.x), y: min(first.y,last.y), width: max(1,abs(last.x-first.x)), height: max(1,abs(last.y-first.y)))
        if tool == .line || tool == .arrow { box = box.insetBy(dx:-max(6,lineWidth*4),dy:-max(6,lineWidth*4)) }
        let annotation = PDFAnnotation(bounds: box, forType: tool == .oval ? .circle : (tool == .rectangle ? .square : .line), withProperties: nil)
        annotation.color = UIColor(inkColor).withAlphaComponent(opacity)
        annotation.contents = L10n.tr(tool.title)
        let border = PDFBorder(); border.lineWidth = lineWidth
        border.style = shapeStyle.pattern == .solid ? .solid : .dashed
        border.dashPattern = shapeStyle.pattern.dash.map { NSNumber(value: Double($0)) }
        annotation.border = border
        if tool == .line || tool == .arrow {
            annotation.startPoint = CGPoint(x: first.x-box.minX, y: first.y-box.minY)
            annotation.endPoint = CGPoint(x: last.x-box.minX, y: last.y-box.minY)
            annotation.startLineStyle = tool == .arrow && shapeStyle.doubleArrow ? .closedArrow : .none
            annotation.endLineStyle = tool == .arrow ? .closedArrow : .none
            annotation.interiorColor = tool == .arrow ? annotation.color : nil
        } else { annotation.interiorColor = shapeStyle.filled ? annotation.color : .clear }
        addAnnotations([(page, annotation)])
        selectedAnnotation = annotation
    }

    func addInk(on page: PDFPage, points: [CGPoint], pressures: [CGFloat?], marker: Bool) {
        guard page.document === document, points.count > 1 else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: max(1,xs.max()!-xs.min()!), height: max(1,ys.max()!-ys.min()!)).insetBy(dx: -lineWidth*2, dy: -lineWidth*2)
        let group = "PaperStudio-" + UUID().uuidString
        var bands: [Int: [UIBezierPath]] = [:]
        var previousBand: Int?
        for i in 1..<points.count {
            let force = pressures.indices.contains(i) ? pressures[i] : nil
            let multiplier = !marker && pressureSensitive ? force.map { 0.25 + min(1,max(0,$0))*1.75 } ?? 1 : 1
            let band = Int((multiplier*8).rounded())
            let local = [points[i-1],points[i]].map { CGPoint(x: $0.x-bounds.minX, y: $0.y-bounds.minY) }
            if previousBand == band, let path = bands[band]?.last { path.addLine(to:local[1]) }
            else { bands[band, default: []].append(AnnotationGeometry.path(local)) }
            previousBand = band
        }
        let additions = bands.sorted { $0.key < $1.key }.map { band, paths -> (PDFPage, PDFAnnotation) in
            let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            annotation.color = UIColor(inkColor).withAlphaComponent(opacity)
            annotation.contents = L10n.tr(marker ? "Marqueur libre" : "Dessiner")
            annotation.setValue(group + "-\(band)", forAnnotationKey: .name)
            let border = PDFBorder(); border.lineWidth = lineWidth * CGFloat(band)/8; annotation.border = border
            for path in paths { annotation.add(path) }
            return (page,annotation)
        }
        addAnnotations(additions, cost: points.count*40 + additions.count*1024)
    }

    func placeMark(_ tool: CanvasTool, on page: PDFPage, at point: CGPoint) {
        guard page.document === document else { return }
        let box = page.bounds(for: .cropBox)
        if tool == .checkmark || tool == .cross {
            let size: CGFloat = 24
            let origin = CGPoint(x: min(max(point.x,box.minX),box.maxX-size), y: min(max(point.y-size,box.minY),box.maxY-size))
            let annotation = PDFAnnotation(bounds: CGRect(origin: origin,size: CGSize(width:size,height:size)), forType: .ink, withProperties: nil)
            annotation.color = UIColor(inkColor).withAlphaComponent(opacity)
            annotation.contents = L10n.tr(tool.title)
            let border = PDFBorder(); border.lineWidth = lineWidth; annotation.border = border
            if tool == .checkmark { annotation.add(AnnotationGeometry.path([CGPoint(x:2,y:12),CGPoint(x:9,y:4),CGPoint(x:22,y:22)])) }
            else {
                annotation.add(AnnotationGeometry.path([CGPoint(x:3,y:3),CGPoint(x:21,y:21)]))
                annotation.add(AnnotationGeometry.path([CGPoint(x:3,y:21),CGPoint(x:21,y:3)]))
            }
            addAnnotations([(page,annotation)])
            selectedAnnotation = annotation
        } else {
            let text: String
            if tool == .date {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: AppLanguage.current.rawValue)
                formatter.dateStyle = .long; formatter.timeStyle = .none
                text = formatter.string(from: stampDate)
            } else { text = stampText }
            let font = UIFont.systemFont(ofSize: tool == .stamp ? 20 : 16, weight: tool == .stamp ? .bold : .regular)
            let width = min(box.width, max(100,(text as NSString).size(withAttributes: [.font:font]).width + 16))
            let bounds = CGRect(x: min(max(point.x,box.minX),box.maxX-width),y: min(max(point.y-32,box.minY),box.maxY-32),width:width,height:32)
            let annotation = PDFAnnotation(bounds:bounds,forType:.freeText,withProperties:nil)
            annotation.contents = text; annotation.font = font; annotation.fontColor = UIColor(inkColor); annotation.color = .clear
            let border = PDFBorder(); border.lineWidth = tool == .stamp ? 1.5 : 0; annotation.border = border
            addAnnotations([(page,annotation)]); selectedAnnotation = annotation
        }
    }

    func addLink(on page: PDFPage, bounds: CGRect, url: URL) {
        guard ["https","http","mailto"].contains(url.scheme?.lowercased() ?? ""), page.document === document else { return }
        let annotation = PDFAnnotation(bounds:bounds,forType:.link,withProperties:nil)
        annotation.url = url
        let border = PDFBorder(); border.lineWidth = 1; annotation.border = border; annotation.color = .systemBlue
        addAnnotations([(page,annotation)])
        selectedAnnotation = annotation
    }
}
