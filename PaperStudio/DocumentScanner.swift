import SwiftUI
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    let onComplete: (Result<[UIImage], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (Result<[UIImage], Error>) -> Void
        init(onComplete: @escaping (Result<[UIImage], Error>) -> Void) { self.onComplete = onComplete }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onComplete(.success((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onComplete(.success([])) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onComplete(.failure(error)) }
    }
}
