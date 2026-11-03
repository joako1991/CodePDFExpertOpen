// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics

enum MuPDFEngine {
    static var version: String { String(cString: ps_pdf_version()) }
    enum Operation: Int32, Sendable { case replaceText = 1, replaceImage = 2, docx = 3 }
    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// All borrowed pointers live inside this synchronous C call. No fz exception crosses Swift.
    static func process(data: Data, password: String, operation: Operation, page: Int = 0,
                        region: CGRect = .zero, text: String = "", fontSize: Float = 12, image: Data = Data()) throws -> Data {
        guard !text.utf8.contains(0), !password.utf8.contains(0), let pageIndex = Int32(exactly: page) else {
            throw EngineError(message: "Texte, mot de passe ou page invalide.")
        }
        var result = PSResult()
        defer { ps_pdf_result_free(&result) }
        let rect = PSRect(x0: Float(region.minX), y0: Float(region.minY), x1: Float(region.maxX), y1: Float(region.maxY))
        let status = data.withUnsafeBytes { input in
            image.withUnsafeBytes { replacement in
                password.withCString { passwordPointer in
                    text.withCString { textPointer in
                        ps_pdf_process(input.bindMemory(to: UInt8.self).baseAddress, data.count,
                                       passwordPointer, operation.rawValue, pageIndex, rect, textPointer, fontSize,
                                       replacement.bindMemory(to: UInt8.self).baseAddress, image.count, &result)
                    }
                }
            }
        }
        guard status == 0, let bytes = result.data, result.length > 0 else {
            throw EngineError(message: result.message.map { String(cString: $0) } ?? "Le moteur PDF a échoué.")
        }
        return Data(bytes: bytes, count: result.length)
    }

    static func processAsync(data: Data, password: String, operation: Operation, page: Int = 0,
                             region: CGRect = .zero, text: String = "", fontSize: Float = 12, image: Data = Data()) async throws -> Data {
        // Each call owns its C context. Cancellation discards the result after a native operation finishes.
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try process(data: data, password: password, operation: operation, page: page,
                                     region: region, text: text, fontSize: fontSize, image: image)
            try Task.checkCancellation()
            return output
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
