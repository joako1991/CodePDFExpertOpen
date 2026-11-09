// SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import PDFKit

enum AnnotationGeometry {
    static func linePath(from a: CGPoint, to b: CGPoint, arrow: Bool, double: Bool, width: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: a); path.addLine(to: b)
        guard arrow else { return path }
        func head(at tip: CGPoint, from tail: CGPoint) {
            let angle = atan2(tip.y - tail.y, tip.x - tail.x), length = max(10, width * 4)
            let left = CGPoint(x: tip.x - length * cos(angle - .pi / 6), y: tip.y - length * sin(angle - .pi / 6))
            let right = CGPoint(x: tip.x - length * cos(angle + .pi / 6), y: tip.y - length * sin(angle + .pi / 6))
            path.move(to: left); path.addLine(to: tip); path.addLine(to: right); path.close()
        }
        head(at: b, from: a)
        if double { head(at: a, from: b) }
        return path
    }

    static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    static func intersects(_ a: CGPoint, _ b: CGPoint, sweep c: CGPoint, _ d: CGPoint, radius: CGFloat) -> Bool {
        let rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y
        let cross = rx * sy - ry * sx
        if abs(cross) > 0.00001 {
            let t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / cross
            let u = ((c.x - a.x) * ry - (c.y - a.y) * rx) / cross
            if (0...1).contains(t), (0...1).contains(u) { return true }
        }
        return min(min(distance(a, to:c,d),distance(b, to:c,d)),min(distance(c, to:a,b),distance(d, to:a,b))) <= radius
    }

    /// Flatten native PDF ink curves, retaining all subpaths in annotation-local coordinates.
    static func polylines(_ path: UIBezierPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = [], points: [CGPoint] = []
        path.cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                if !points.isEmpty { result.append(points) }; points = [element.points[0]]
            case .addLineToPoint: points.append(element.points[0])
            case .addQuadCurveToPoint:
                guard let start = points.last else { return }
                let control = element.points[0], end = element.points[1]
                for i in 1...20 {
                    let t = CGFloat(i) / 20, u = 1 - t
                    points.append(CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                                          y: u*u*start.y + 2*u*t*control.y + t*t*end.y))
                }
            case .addCurveToPoint:
                guard let start = points.last else { return }
                let c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                for i in 1...24 {
                    let t = CGFloat(i) / 24, u = 1 - t
                    points.append(CGPoint(x: u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x,
                                          y: u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y))
                }
            case .closeSubpath: if let first = points.first { points.append(first) }
            @unknown default: break
            }
        }
        if !points.isEmpty { result.append(points) }
        return result
    }

    static func path(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Cut a swept eraser capsule out of an ink path, rather than painting white over it.
    static func erased(_ points: [CGPoint], from a: CGPoint, to b: CGPoint, radius: CGFloat) -> [[CGPoint]] {
        guard points.count > 1 else { return [] }
        func outside(_ p: CGPoint) -> Bool { distance(p, to: a, b) > radius }
        var dense: [CGPoint] = [points[0]]
        for index in 1..<points.count {
            let p = points[index - 1], q = points[index]
            let steps = max(1, Int(ceil(hypot(q.x-p.x, q.y-p.y) / max(0.5, radius / 3))))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                dense.append(CGPoint(x: p.x + (q.x-p.x)*t, y: p.y + (q.y-p.y)*t))
            }
        }
        var fragments: [[CGPoint]] = [], fragment: [CGPoint] = outside(dense[0]) ? [dense[0]] : []
        for i in 1..<dense.count {
            let p = dense[i-1], q = dense[i], pOut = outside(p), qOut = outside(q)
            if pOut != qOut {
                var lo: CGFloat = 0, hi: CGFloat = 1
                for _ in 0..<12 {
                    let t = (lo+hi)/2, mid = CGPoint(x: p.x+(q.x-p.x)*t, y: p.y+(q.y-p.y)*t)
                    if outside(mid) == pOut { lo = t } else { hi = t }
                }
                let t = (lo+hi)/2, edge = CGPoint(x: p.x+(q.x-p.x)*t, y: p.y+(q.y-p.y)*t)
                if pOut { fragment.append(edge); if fragment.count > 1 { fragments.append(fragment) }; fragment = [] }
                else { fragment = [edge] }
            }
            if qOut { fragment.append(q) }
        }
        if fragment.count > 1 { fragments.append(fragment) }
        return fragments
    }

    static func erase(_ annotation: PDFAnnotation, from a: CGPoint, to b: CGPoint, radius: CGFloat, partial: Bool) -> (changed: Bool, replacement: PDFAnnotation?) {
        guard annotation.type == "Ink", let paths = annotation.paths else { return (false, annotation) }
        let offset = annotation.bounds.origin
        let a = CGPoint(x: a.x-offset.x, y: a.y-offset.y), b = CGPoint(x: b.x-offset.x, y: b.y-offset.y)
        let radius = radius + (annotation.border?.lineWidth ?? 1) / 2
        let lines = paths.flatMap(polylines)
        let hit = lines.contains { line in
            zip(line, line.dropFirst()).contains { intersects($0.0, $0.1, sweep: a, b, radius: radius) }
        }
        guard hit else { return (false, annotation) }
        guard partial else { return (true, nil) }
        let remaining = lines.flatMap { erased($0, from: a, to: b, radius: radius) }
        guard !remaining.isEmpty, let copy = annotation.copy() as? PDFAnnotation else { return (true, nil) }
        for path in copy.paths ?? [] { copy.remove(path) }
        for points in remaining { copy.add(path(points)) }
        // A saved /AP stream otherwise keeps drawing the ink that was just erased.
        copy.removeValue(forAnnotationKey: .appearanceDictionary)
        return (true, copy)
    }
}
