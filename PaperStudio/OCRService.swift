import UIKit
import PDFKit
import Vision
import CoreText

struct RecognizedLine: Sendable {
    let text: String
    /// Vision uses normalized coordinates with the origin at the bottom-left.
    let bounds: CGRect
}

enum OCRService {
    static func lines(in image: CGImage) async throws -> [RecognizedLine] {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US", "es-ES"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { result in
                result.topCandidates(1).first.map { RecognizedLine(text: $0.string, bounds: result.boundingBox) }
            }
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    @MainActor
    static func searchablePDF(_ document: PDFDocument, progress: (Int, Int) -> Void) async throws -> Data {
        guard !document.isLocked, document.allowsCopying, document.pageCount > 0 else { throw StudioError.invalidPDF }
        let output = PDFDocument()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress(index + 1, document.pageCount)
            guard let page = document.page(at: index) else { throw StudioError.invalidPDF }
            let image = PDFConversions.image(of: page, quality: .detailed)
            guard let cgImage = image.cgImage else { throw StudioError.invalidPDF }
            let lines = try await lines(in: cgImage)
            try Task.checkCancellation()
            let size = PDFConversions.displayedSize(of: page)
            let data = pageData(image: image, size: size, lines: lines)
            guard let rendered = PDFDocument(data: data), let copied = rendered.page(at: 0)?.copy() as? PDFPage else { throw StudioError.writeFailed }
            output.insert(copied, at: output.pageCount)
        }
        guard let data = output.dataRepresentation() else { throw StudioError.writeFailed }
        return data
    }

    @MainActor
    static func pageData(image: UIImage, size: CGSize, lines: [RecognizedLine]) -> Data {
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            image.draw(in: bounds)
            let context = renderer.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.setTextDrawingMode(.invisible)
            for line in lines where !line.text.isEmpty {
                let rect = CGRect(x: line.bounds.minX * size.width, y: line.bounds.minY * size.height,
                                  width: line.bounds.width * size.width, height: line.bounds.height * size.height)
                let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.85), nil)
                let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let ctLine = CTLineCreateWithAttributedString(attributed)
                let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.1)
                context.scaleBy(x: rect.width / max(1, width), y: 1)
                context.textPosition = .zero
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
            context.restoreGState()
        }
    }
}
