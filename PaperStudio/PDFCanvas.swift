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
            Task { @MainActor in
                let index = view.document?.index(for: page) ?? 0
                if workspace?.pageIndex != index { workspace?.pageIndex = index }
            }
        }
        for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak view, weak workspace] notification in
                guard let input = notification.object as? UIView, let view, input.isDescendant(of: view) else { return }
                if (view as? DrawingPDFView)?.isInlineTextInput(input) == true { return }
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
        let background: UIColor = nightMode ? .darkGray : UIColor(white: 0.91, alpha: 1)
        if view.backgroundColor != background { view.backgroundColor = background }
        (view as? DrawingPDFView)?.configureTool()
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        (view as? DrawingPDFView)?.finishTextEntry()
        (view as? DrawingPDFView)?.cancelToolGesture()
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

@MainActor
private final class CanvasFrameTarget: NSObject {
    weak var view: DrawingPDFView?
    @objc func tick(_ link: CADisplayLink) { view?.renderInteractionFrame() }
}

/// Keep canvas touches independent of PDFKit's delayed text/double-tap recognizers.
private final class CanvasGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current.accessibilityIdentifier == "inline-annotation-text" || current is UIControl { return false }
            view = current.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UIPinchGestureRecognizer || ((other as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 1) > 1
    }
}

@MainActor
private final class CanvasTextDelegate: NSObject, UITextViewDelegate {
    weak var view: DrawingPDFView?
    func textViewDidEndEditing(_ textView: UITextView) { view?.finishTextEntry() }
}

/// Gestures convert view coordinates to PDF page coordinates, including zoom and rotation.
@MainActor
final class DrawingPDFView: PDFView {
    weak var workspace: PDFWorkspace?
    private var stroke: [CGPoint] = []
    private var strokePage: PDFPage?
    private var gestureSelection: PDFSelection?
    private var movingAnnotation: PDFAnnotation?
    private var initialBounds: CGRect = .zero
    private let preview = CAShapeLayer()
    private let selectionFrame = CAShapeLayer()
    private var resizing = false
    private var displayLink: CADisplayLink?
    private let frameTarget = CanvasFrameTarget()
    private let canvasGestures = CanvasGestureDelegate()
    private let textDelegate = CanvasTextDelegate()
    private var textInput: UITextView?
    private var textPlacement: AnnotationPlacement?
    private var editedTextAnnotation: PDFAnnotation?
    private var initialTextStyle: TextStyle?
    private var pendingSelection = false
    private var previewDirty = false
    private var penPath = UIBezierPath()
    private var renderedPointCount = 0
    private lazy var drawingPan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private lazy var annotationTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    private var configuredTool: CanvasTool?
    private weak var pageScroll: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawingPan.maximumNumberOfTouches = 1
        drawingPan.delegate = canvasGestures
        annotationTap.delegate = canvasGestures
        drawingPan.delaysTouchesBegan = false
        annotationTap.delaysTouchesBegan = false
        annotationTap.delaysTouchesEnded = false
        frameTarget.view = self
        textDelegate.view = self
        addGestureRecognizer(drawingPan)
        addGestureRecognizer(annotationTap)
        preview.fillColor = UIColor.clear.cgColor
        preview.lineCap = .round
        preview.zPosition = 100
        preview.contentsScale = UIScreen.main.scale
        preview.name = "tool-preview"
        preview.actions = ["path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(),
                           "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(preview)
        selectionFrame.fillColor = UIColor.clear.cgColor
        selectionFrame.strokeColor = UIColor.systemBlue.cgColor
        selectionFrame.lineWidth = 1.5
        selectionFrame.lineDashPattern = [5, 3]
        selectionFrame.zPosition = 101
        selectionFrame.contentsScale = UIScreen.main.scale
        selectionFrame.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(selectionFrame)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutTextEntry), name: .PDFViewScaleChanged, object: self)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    func configureTool() {
        guard let workspace else { return }
        let tool = workspace.activeTool
        if configuredTool != tool {
            cancelToolGesture()
            configuredTool = tool
            drawingPan.isEnabled = [.pen, .rectangle, .oval, .move, .text].contains(tool) || tool.selectsText
            annotationTap.isEnabled = [.move, .erase, .targetImage, .text, .note, .signature].contains(tool)
        }
        configureScrolling(drawing: drawingPan.isEnabled)
        selectionFrame.path = nil
        if tool == .move, let annotation = workspace.selectedAnnotation, let page = annotation.page {
            let rect = convert(annotation.bounds, from: page)
            let outline = UIBezierPath(rect: rect)
            if annotation.type == "FreeText" {
                outline.append(UIBezierPath(ovalIn: CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12)))
            }
            selectionFrame.path = outline.cgPath
        }
    }

    @objc private func selectionChanged() {
        guard strokePage == nil else { return }
        pendingSelection = workspace?.activeTool.selectsText == true && currentSelection != nil
        if pendingSelection { previewDirty = true; startFrames() }
        else if strokePage == nil { stopFrames(); preview.path = nil }
    }

    private func hasActiveGesture(in view: UIView) -> Bool {
        if (view.gestureRecognizers ?? []).contains(where: { $0.state == .began || $0.state == .changed }) { return true }
        return view.subviews.contains { hasActiveGesture(in: $0) }
    }

    private func startFrames() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: frameTarget, selector: #selector(CanvasFrameTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(UIScreen.main.maximumFramesPerSecond),
                                                      preferred: Float(UIScreen.main.maximumFramesPerSecond))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFrames() { displayLink?.invalidate(); displayLink = nil }

    // One visual update per display refresh, with no fixed debounce or implicit layer animation.
    func renderInteractionFrame() {
        keepFeedbackAbovePages()
        if strokePage != nil {
            if previewDirty {
                previewDirty = false
                if workspace?.activeTool.selectsText == true { updateTextSelection() }
                else { drawPreview() }
            }
            return
        }
        guard pendingSelection, let workspace, workspace.activeTool.selectsText, let selection = currentSelection else {
            stopFrames(); return
        }
        if previewDirty { previewDirty = false; drawMarkupPreview(selection) }
        guard !hasActiveGesture(in: self) else { return }
        pendingSelection = false
        workspace.commitToolSelection(selection)
        clearSelection()
        preview.path = nil
        stopFrames()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        selectionFrame.frame = bounds
        keepFeedbackAbovePages()
        configureTool()
        layoutTextEntry()
    }

    private func keepFeedbackAbovePages() {
        let expected: [CALayer] = [preview, selectionFrame] + (textInput.map { [$0.layer] } ?? [])
        let actual = Array(layer.sublayers?.suffix(expected.count) ?? [])
        guard actual.count != expected.count || zip(actual, expected).contains(where: { $0.0 !== $0.1 }) else { return }
        // PDFKit can insert opaque page views later. Preserve drawing order as well as depth.
        layer.addSublayer(preview)
        layer.addSublayer(selectionFrame)
        if let textInput { bringSubviewToFront(textInput) }
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        for child in view.subviews {
            if let scroll = child as? UIScrollView { return scroll }
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }

    private func configureScrolling(drawing: Bool) {
        if pageScroll?.isDescendant(of: self) != true { pageScroll = findScroll(in: self) }
        let touches = drawing ? 2 : 1
        if pageScroll?.panGestureRecognizer.minimumNumberOfTouches != touches {
            pageScroll?.panGestureRecognizer.minimumNumberOfTouches = touches
        }
        pageScroll?.panGestureRecognizer.isEnabled = textInput == nil
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let workspace else { return }
        let location = gesture.location(in: self)
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if workspace.activeTool == .targetImage {
            workspace.imageTarget = ContentImageTarget(page: document?.index(for: page) ?? 0, point: point)
            return
        }
        if workspace.activeTool == .text || workspace.activeTool == .note {
            if let annotation = page.annotations.reversed().first(where: {
                ($0.type == "FreeText" || $0.type == "Text") && $0.bounds.contains(point)
            }) {
                beginTextEntry(annotation: annotation)
                return
            }
            let rect = CGRect(x: location.x, y: location.y, width: (workspace.activeTool == .note ? 30 : 220) * scaleFactor,
                              height: (workspace.activeTool == .note ? 30 : 80) * scaleFactor)
            beginTextEntry(on: page, bounds: convert(rect, to: page), note: workspace.activeTool == .note)
            return
        }
        if workspace.activeTool == .signature {
            workspace.addSignature(workspace.signatureStrokes, size: workspace.signatureSize, on: page, at: point)
            return
        }
        let hit = page.annotations.reversed().first { $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }
        if workspace.activeTool == .erase, let hit { workspace.removeAnnotation(hit) }
        else { workspace.selectedAnnotation = hit }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            beginToolGesture(at: CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            updateToolGesture(at: location)
        case .changed:
            updateToolGesture(at: location)
        case .ended:
            endToolGesture(at: location)
        case .cancelled, .failed: cancelToolGesture()
        default: break
        }
    }

    func beginToolGesture(at origin: CGPoint) {
        finishTextEntry()
        cancelToolGesture()
        guard let workspace, let page = page(for: origin, nearest: false) else { return }
        strokePage = page
        let point = convert(origin, to: page)
        stroke = [point]
        let index = document?.index(for: page) ?? 0
        if workspace.pageIndex != index { workspace.pageIndex = index }
        if workspace.activeTool == .move {
            if let selected = workspace.selectedAnnotation, selected.type == "FreeText", selected.page === page {
                let bounds = convert(selected.bounds, from: page)
                resizing = hypot(origin.x - bounds.maxX, origin.y - bounds.maxY) < 22
                if resizing { movingAnnotation = selected }
            }
            if !resizing { movingAnnotation = page.annotations.reversed().first { $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) } }
            initialBounds = movingAnnotation?.bounds ?? .zero
            if workspace.selectedAnnotation !== movingAnnotation { workspace.selectedAnnotation = movingAnnotation }
        }
        previewDirty = true
        startFrames()
    }

    func updateToolGesture(at location: CGPoint) {
        guard let page = strokePage else { return }
        let box = page.bounds(for: .cropBox), point = convert(location, to: page)
        let clipped = CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
        if stroke.last == clipped { return }
        stroke.append(clipped)
        previewDirty = true
    }

    func endToolGesture(at location: CGPoint) {
        updateToolGesture(at: location)
        renderInteractionFrame() // Include the final touch even if it arrived between display refreshes.
        defer { clearGesture(); stopFrames() }
        guard let workspace, let page = strokePage, stroke.count > 1 else { return }
        if workspace.activeTool.selectsText {
            pendingSelection = false
            if let selection = gestureSelection ?? currentSelection { workspace.commitToolSelection(selection) }
            clearSelection()
        } else if workspace.activeTool == .text {
            let first = stroke[0], last = stroke[stroke.count - 1]
            beginTextEntry(on: page, bounds: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                width: abs(last.x - first.x), height: abs(last.y - first.y)))
        } else if workspace.activeTool == .move, let annotation = movingAnnotation {
            let bounds = movedBounds(on: page)
            annotation.bounds = initialBounds
            workspace.moveAnnotation(annotation, to: bounds)
        } else if [.pen, .rectangle, .oval].contains(workspace.activeTool) {
            let points = workspace.activeTool == .pen ? stroke : [stroke[0], stroke[stroke.count - 1]]
            workspace.addDrawing(on: page, points: points, tool: workspace.activeTool)
        }
    }

    private func updateTextSelection() {
        guard let page = strokePage, let first = stroke.first, let last = stroke.last else { return }
        let selection = page.selection(from: first, to: last)
        gestureSelection = selection
        // Markup draws directly under the finger instead of showing a blue selection first.
        if workspace?.activeTool.markup == nil { setCurrentSelection(selection, animate: false) }
        if let selection { drawMarkupPreview(selection) }
        else { preview.path = nil }
    }

    private func drawMarkupPreview(_ selection: PDFSelection) {
        guard let workspace, let markup = workspace.activeTool.markup else { preview.path = nil; return }
        let path = UIBezierPath()
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                if markup == .highlight { path.append(UIBezierPath(rect: convert(bounds, from: page))) }
                else {
                    let y = markup == .underline ? bounds.minY : bounds.midY
                    path.move(to: convert(CGPoint(x: bounds.minX, y: y), from: page))
                    path.addLine(to: convert(CGPoint(x: bounds.maxX, y: y), from: page))
                }
            }
        }
        preview.fillColor = markup == .highlight ? UIColor(workspace.inkColor).withAlphaComponent(0.35).cgColor : UIColor.clear.cgColor
        preview.strokeColor = markup == .highlight ? UIColor.clear.cgColor : UIColor(workspace.inkColor).cgColor
        preview.lineWidth = workspace.lineWidth * scaleFactor
        preview.path = path.cgPath
    }

    private func movedBounds(on page: PDFPage) -> CGRect {
        guard let first = stroke.first, let last = stroke.last else { return initialBounds }
        let box = page.bounds(for: .cropBox)
        if resizing {
            let originalView = convert(initialBounds, from: page)
            let end = convert(last, from: page)
            let resized = CGRect(x: originalView.minX, y: originalView.minY,
                                 width: max(32, end.x - originalView.minX), height: max(24, end.y - originalView.minY))
            return convert(resized, to: page).intersection(box)
        }
        var result = initialBounds.offsetBy(dx: last.x - first.x, dy: last.y - first.y)
        result.origin.x = min(max(result.minX, box.minX), max(box.minX, box.maxX - result.width))
        result.origin.y = min(max(result.minY, box.minY), max(box.minY, box.maxY - result.height))
        return result
    }

    private func drawPreview() {
        guard let workspace, let page = strokePage, let first = stroke.first, let last = stroke.last else { return }
        let path = UIBezierPath()
        if workspace.activeTool == .move {
            guard let annotation = movingAnnotation else { return }
            let before = convert(annotation.bounds, from: page)
            annotation.bounds = movedBounds(on: page)
            annotationsChanged(on: page)
            let after = convert(annotation.bounds, from: page)
            setNeedsDisplay(before.union(after).insetBy(dx: -4, dy: -4))
            path.append(UIBezierPath(rect: after))
        } else if workspace.activeTool == .pen {
            for index in renderedPointCount..<stroke.count {
                let point = stroke[index]
                let mapped = convert(point, from: page)
                if index == 0 { penPath.move(to: mapped) } else { penPath.addLine(to: mapped) }
            }
            renderedPointCount = stroke.count
            path.append(penPath)
        } else {
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            let viewRect = convert(rect, from: page)
            path.append(workspace.activeTool == .oval ? UIBezierPath(ovalIn: viewRect) : UIBezierPath(rect: viewRect))
        }
        preview.strokeColor = UIColor(workspace.inkColor).cgColor
        preview.fillColor = UIColor.clear.cgColor
        preview.lineWidth = workspace.lineWidth * scaleFactor
        preview.path = path.cgPath
    }

    private func clearGesture() {
        stroke = []; strokePage = nil; gestureSelection = nil; movingAnnotation = nil; resizing = false; preview.path = nil
        penPath = UIBezierPath(); renderedPointCount = 0; previewDirty = false
    }

    func cancelToolGesture() {
        stopFrames()
        pendingSelection = false
        if let annotation = movingAnnotation, let page = annotation.page {
            let before = convert(annotation.bounds, from: page)
            annotation.bounds = initialBounds
            annotationsChanged(on: page)
            setNeedsDisplay(before.union(convert(initialBounds, from: page)).insetBy(dx: -4, dy: -4))
        }
        if workspace?.activeTool.selectsText == true { clearSelection() }
        clearGesture()
    }

    func isInlineTextInput(_ view: UIView) -> Bool { view === textInput }

    func beginTextEntry(annotation: PDFAnnotation) {
        guard let workspace, let page = annotation.page, page.document === document else { return }
        finishTextEntry()
        workspace.readTextStyle(from: annotation)
        beginTextEntry(on: page, bounds: annotation.bounds, note: annotation.type == "Text", annotation: annotation)
    }

    func beginTextEntry(on page: PDFPage, bounds: CGRect, note: Bool = false, annotation: PDFAnnotation? = nil) {
        finishTextEntry()
        guard let workspace, page.document === document, document?.allowsDocumentChanges == true else { return }
        let clipped = bounds.standardized.intersection(page.bounds(for: .cropBox))
        guard !clipped.isNull, clipped.width >= 12, clipped.height >= 12 else { return }
        textPlacement = AnnotationPlacement(page: page, bounds: clipped, note: note)
        editedTextAnnotation = annotation
        initialTextStyle = workspace.textStyle
        let input = UITextView()
        textInput = input
        input.accessibilityIdentifier = "inline-annotation-text"
        input.delegate = textDelegate
        input.text = annotation?.contents ?? ""
        input.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        input.layer.borderColor = UIColor.systemBlue.cgColor
        input.layer.borderWidth = 1
        input.layer.zPosition = 102
        input.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
        input.textContainer.lineFragmentPadding = 0
        input.isScrollEnabled = true
        let bar = UIToolbar()
        bar.items = [UIBarButtonItem(title: L10n.tr("Annuler"), style: .plain, target: self, action: #selector(cancelTextEntry)),
                     UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                     UIBarButtonItem(title: L10n.tr("Terminer"), style: .done, target: self, action: #selector(finishTextEntry))]
        bar.sizeToFit()
        input.inputAccessoryView = bar
        addSubview(input)
        updateTextEntryStyle()
        layoutTextEntry()
        configureScrolling(drawing: drawingPan.isEnabled)
        input.becomeFirstResponder()
        workspace.selectedAnnotation = annotation
    }

    func updateTextEntryStyle() {
        guard let input = textInput, let workspace else { return }
        let font = workspace.textStyle.font.withSize(workspace.textStyle.font.pointSize * scaleFactor)
        let color = UIColor(workspace.textStyle.color)
        if input.font != font { input.font = font }
        if input.textColor != color { input.textColor = color }
    }

    @objc private func layoutTextEntry() {
        guard let input = textInput, let placement = textPlacement else { return }
        var frame = convert(placement.bounds, from: placement.page)
        // Notes have a small PDF icon but a comfortable writing area while editing.
        if placement.note { frame.size = CGSize(width: max(240, frame.width), height: max(100, frame.height)) }
        if input.frame != frame { input.frame = frame }
        updateTextEntryStyle()
    }

    @objc func finishTextEntry() {
        guard let input = textInput, let placement = textPlacement else { return }
        let annotation = editedTextAnnotation, text = input.text ?? "", styleBefore = initialTextStyle
        textInput = nil; textPlacement = nil; editedTextAnnotation = nil; initialTextStyle = nil
        input.resignFirstResponder()
        input.removeFromSuperview()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let annotation {
                if annotation.contents != text || workspace?.textStyle != styleBefore {
                    workspace?.updateTextAnnotation(annotation, text: text)
                }
            }
            else { workspace?.placeText(text, at: placement) }
        }
        configureScrolling(drawing: drawingPan.isEnabled)
    }

    @objc func cancelTextEntry() {
        guard let input = textInput else { return }
        textInput = nil; textPlacement = nil; editedTextAnnotation = nil; initialTextStyle = nil
        input.resignFirstResponder()
        input.removeFromSuperview()
        configureScrolling(drawing: drawingPan.isEnabled)
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
