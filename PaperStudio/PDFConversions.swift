import UIKit
import PDFKit

enum RasterQuality: String, CaseIterable, Identifiable {
    case compact, balanced, detailed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Compact · 100 ppp"
        case .balanced: return "Équilibré · 150 ppp"
        case .detailed: return "Détaillé · 200 ppp"
        }
    }
    var scale: CGFloat {
        switch self { case .compact: return 100 / 72; case .balanced: return 150 / 72; case .detailed: return 200 / 72 }
    }
    var jpegQuality: CGFloat {
        switch self { case .compact: return 0.5; case .balanced: return 0.75; case .detailed: return 0.9 }
    }
}

/// Redaction coordinates are normalized against the *displayed*, rotated page.
/// Source content is burned into a new bitmap before any image is embedded in the output.
struct MaskedRegion: Identifiable {
    let id = UUID()
    let rect: CGRect
}

@MainActor
enum PDFConversions {
    static func displayedSize(of page: PDFPage) -> CGSize {
        let size = page.bounds(for: .cropBox).size
        return abs(page.rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
    }

    static func image(of page: PDFPage, quality: RasterQuality) -> UIImage {
        let size = displayedSize(of: page)
        // Bound the bitmap to 16 megapixels, including unusually large engineering pages.
        let pixels = max(1, size.width * size.height * quality.scale * quality.scale)
        let scale = quality.scale * min(1, sqrt(16_000_000 / pixels))
        return page.thumbnail(of: CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale)), for: .cropBox)
    }

    static func burnedImage(_ source: UIImage, regions: [MaskedRegion]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: source.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: source.size)
            UIColor.white.setFill(); context.cgContext.fill(bounds)
            source.draw(in: bounds)
            UIColor.black.setFill()
            for region in regions {
                let normalized = region.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !normalized.isNull, !normalized.isEmpty else { continue }
                // Expand by a pixel to avoid fractional antialiased edges exposing source pixels.
                let mask = CGRect(x: normalized.minX * bounds.width, y: normalized.minY * bounds.height,
                                  width: normalized.width * bounds.width, height: normalized.height * bounds.height)
                    .insetBy(dx: -1, dy: -1).intersection(bounds)
                context.cgContext.setShouldAntialias(false)
                context.cgContext.fill(mask)
            }
        }
    }

    static func rasterized(_ document: PDFDocument, quality: RasterQuality, masks: [Int: [MaskedRegion]] = [:]) throws -> Data {
        guard !document.isLocked, document.pageCount > 0, document.allowsCopying else { throw StudioError.invalidPDF }
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for index in 0..<document.pageCount {
                autoreleasepool {
                    guard let page = document.page(at: index) else { return }
                    let pageBounds = CGRect(origin: .zero, size: displayedSize(of: page))
                    context.beginPage(withBounds: pageBounds, pageInfo: [:])
                    let burned = burnedImage(image(of: page, quality: quality), regions: masks[index] ?? [])
                    // The embedded JPEG is generated from the masked bitmap, never from the original page.
                    let jpeg = burned.jpegData(compressionQuality: quality.jpegQuality).flatMap { UIImage(data: $0) } ?? burned
                    jpeg.draw(in: pageBounds)
                }
            }
        }
    }

    static func temporaryFile(data: Data, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func fromImages(_ images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw StudioError.invalidPDF }
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            for image in images {
                context.beginPage()
                UIColor.white.setFill(); context.cgContext.fill(pageBounds)
                let content = pageBounds.insetBy(dx: 24, dy: 24)
                let scale = min(content.width / max(1, image.size.width), content.height / max(1, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
    }
}
