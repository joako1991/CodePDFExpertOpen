import SwiftUI
import PDFKit

struct PDFCanvas: UIViewRepresentable {
    @ObservedObject var workspace: PDFWorkspace
    var nightMode: Bool

    func makeUIView(context: Context) -> PDFView {
        let view = DrawingPDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = workspace.document
        view.delegate = context.coordinator
        workspace.pdfView = view
        view.workspace = workspace
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak workspace] notification in
            guard let view = notification.object as? PDFView, let page = view.currentPage else { return }
            Task { @MainActor in workspace?.pageIndex = view.document?.index(for: page) ?? 0 }
        }
        for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak view, weak workspace] notification in
                guard let input = notification.object as? UIView, let view, input.isDescendant(of: view) else { return }
                Task { @MainActor in workspace?.markExternalChange() }
            }
            context.coordinator.formObservers.append(observer)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== workspace.document {
            view.document = workspace.document
            if let page = workspace.document?.page(at: workspace.pageIndex) { view.go(to: page) }
        }
        view.backgroundColor = nightMode ? .darkGray : UIColor(white: 0.91, alpha: 1)
        (view as? DrawingPDFView)?.configureTool()
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, PDFViewDelegate {
        var observer: NSObjectProtocol?
        var formObservers: [NSObjectProtocol] = []
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            for observer in formObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Gestures convert view coordinates to PDF page coordinates, including zoom and rotation.
@MainActor
final class DrawingPDFView: PDFView {
    weak var workspace: PDFWorkspace?
    private var stroke: [CGPoint] = []
    private var strokePage: PDFPage?
    private var movingAnnotation: PDFAnnotation?
    private var initialBounds: CGRect = .zero
    private let preview = CAShapeLayer()
    private lazy var drawingPan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private lazy var annotationTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    private var configuredTool: CanvasTool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawingPan.maximumNumberOfTouches = 1
        drawingPan.delegate = self
        annotationTap.delegate = self
        addGestureRecognizer(drawingPan)
        addGestureRecognizer(annotationTap)
        preview.fillColor = UIColor.clear.cgColor
        preview.lineCap = .round
        layer.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configureTool() {
        guard let tool = workspace?.activeTool, configuredTool != tool else { return }
        configuredTool = tool
        drawingPan.isEnabled = tool != .read && tool != .erase && tool != .targetImage
        annotationTap.isEnabled = tool == .move || tool == .erase || tool == .targetImage
        // Keep pinch zoom available while reserving one-finger dragging for the active tool.
        setScrolling(in: self, enabled: tool == .read || tool == .erase || tool == .targetImage)
        preview.path = nil
    }

    private func setScrolling(in view: UIView, enabled: Bool) {
        for child in view.subviews {
            if let scroll = child as? UIScrollView { scroll.panGestureRecognizer.isEnabled = enabled }
            setScrolling(in: child, enabled: enabled)
        }
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let workspace else { return }
        let location = gesture.location(in: self)
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if workspace.activeTool == .targetImage {
            workspace.imageTarget = ContentImageTarget(page: document?.index(for: page) ?? 0, point: point)
            workspace.activeTool = .read
            return
        }
        let hit = page.annotations.reversed().first { $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
        if workspace.activeTool == .erase, let hit { workspace.removeAnnotation(hit) }
        else { workspace.selectedAnnotation = hit }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let workspace else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let page = page(for: location, nearest: false) else { return }
            strokePage = page
            let point = convert(location, to: page)
            stroke = [point]
            workspace.pageIndex = document?.index(for: page) ?? 0
            if workspace.activeTool == .move {
                movingAnnotation = page.annotations.reversed().first { $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
                initialBounds = movingAnnotation?.bounds ?? .zero
                workspace.selectedAnnotation = movingAnnotation
            }
        case .changed:
            guard let page = strokePage else { return }
            let box = page.bounds(for: .cropBox)
            let point = convert(location, to: page)
            stroke.append(CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY)))
            drawPreview()
        case .ended:
            defer { clearGesture() }
            guard let page = strokePage, stroke.count > 1 else { return }
            if workspace.activeTool == .move, let annotation = movingAnnotation {
                workspace.moveAnnotation(annotation, to: movedBounds(on: page))
            } else if [.pen, .rectangle, .oval].contains(workspace.activeTool) {
                let points = workspace.activeTool == .pen ? stroke : [stroke[0], stroke[stroke.count - 1]]
                workspace.addDrawing(on: page, points: points, tool: workspace.activeTool)
            }
        case .cancelled, .failed: clearGesture()
        default: break
        }
    }

    private func movedBounds(on page: PDFPage) -> CGRect {
        guard let first = stroke.first, let last = stroke.last else { return initialBounds }
        let box = page.bounds(for: .cropBox)
        var result = initialBounds.offsetBy(dx: last.x - first.x, dy: last.y - first.y)
        result.origin.x = min(max(result.minX, box.minX), max(box.minX, box.maxX - result.width))
        result.origin.y = min(max(result.minY, box.minY), max(box.minY, box.maxY - result.height))
        return result
    }

    private func drawPreview() {
        guard let workspace, let page = strokePage, let first = stroke.first, let last = stroke.last else { return }
        let path = UIBezierPath()
        if workspace.activeTool == .move {
            guard movingAnnotation != nil else { return }
            path.append(UIBezierPath(rect: convert(movedBounds(on: page), from: page)))
        } else if workspace.activeTool == .pen {
            for (index, point) in stroke.enumerated() {
                let mapped = convert(point, from: page)
                if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
            }
        } else {
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            let viewRect = convert(rect, from: page)
            path.append(workspace.activeTool == .oval ? UIBezierPath(ovalIn: viewRect) : UIBezierPath(rect: viewRect))
        }
        preview.strokeColor = UIColor(workspace.inkColor).cgColor
        preview.lineWidth = workspace.lineWidth * scaleFactor
        preview.path = path.cgPath
    }

    private func clearGesture() {
        stroke = []; strokePage = nil; movingAnnotation = nil; preview.path = nil
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
