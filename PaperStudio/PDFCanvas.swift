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
                (view as? DrawingPDFView)?.focusReadingPage()
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
        (view as? DrawingPDFView)?.configureReading(workspace.reading)
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

@MainActor
private final class CanvasScribbleDelegate: NSObject, @preconcurrency UIIndirectScribbleInteractionDelegate {
    typealias ElementIdentifier = String
    weak var view: DrawingPDFView?
    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([String]) -> Void) {
        completion(view?.acceptsScribble == true ? ["page-text"] : [])
    }
    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: String) -> Bool { view?.isEditingText == true }
    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: String) -> CGRect { view?.bounds ?? .zero }
    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded elementIdentifier: String, referencePoint point: CGPoint, completion: @escaping ((UIResponder & UITextInput)?) -> Void) {
        completion(view?.focusScribble(at:point))
    }
    func indirectScribbleInteraction(_ interaction: UIInteraction, shouldDelayFocusForElement elementIdentifier: String) -> Bool { false }
}

/// Keep Pencil force and coalesced samples that a plain pan recognizer would discard.
private final class CanvasPanRecognizer: UIPanGestureRecognizer {
    var samples: [(CGPoint, CGFloat?)] = []
    private func record(_ touches: Set<UITouch>, _ event: UIEvent) {
        guard let view, touches.count == 1, let touch = touches.first else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            let force: CGFloat? = sample.type == .stylus && sample.maximumPossibleForce > 0 ? sample.force / sample.maximumPossibleForce : nil
            samples.append((sample.location(in: view), force))
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { record(touches,event); super.touchesBegan(touches,with:event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { record(touches,event); super.touchesMoved(touches,with:event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { record(touches,event); super.touchesEnded(touches,with:event) }
    override func reset() { super.reset(); samples.removeAll() }
}

/// Gestures convert view coordinates to PDF page coordinates, including zoom and rotation.
@MainActor
final class DrawingPDFView: PDFView {
    weak var workspace: PDFWorkspace?
    private var stroke: [CGPoint] = []
    private var strokePressures: [CGFloat?] = []
    private var strokePage: PDFPage?
    private var gestureSelection: PDFSelection?
    private var movingAnnotation: PDFAnnotation?
    private var movingGroup: [(PDFAnnotation,CGRect)] = []
    private var initialBounds: CGRect = .zero
    private let preview = CAShapeLayer()
    private let pressurePreview = CALayer()
    private var pressureBands: [Int: CAShapeLayer] = [:]
    private var eraserBefore: [PDFAnnotation]?
    private var erasedPointCount = 0
    private let selectionFrame = CAShapeLayer()
    private var resizing = false
    private var displayLink: CADisplayLink?
    private let frameTarget = CanvasFrameTarget()
    private let canvasGestures = CanvasGestureDelegate()
    private let textDelegate = CanvasTextDelegate()
    private let scribbleDelegate = CanvasScribbleDelegate()
    private var textInput: UITextView?
    private var textPlacement: AnnotationPlacement?
    private var editedTextAnnotation: PDFAnnotation?
    private var initialTextStyle: TextStyle?
    private var textBar: UIToolbar?
    private var barStyle: TextStyle?
    private var pendingSelection = false
    private var previewDirty = false
    private var penPath = UIBezierPath()
    private var renderedPointCount = 0
    private lazy var drawingPan = CanvasPanRecognizer(target: self, action: #selector(drag(_:)))
    private lazy var annotationTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    private var configuredTool: CanvasTool?
    private var configuredScribble = false
    private weak var pageScroll: UIScrollView?
    private var readingSettings = ReadingSettings()
    private var marginPage: ObjectIdentifier?
    private var marginSize: CGSize = .zero

    func configureReading(_ settings: ReadingSettings) {
        let layoutChanged = settings.layout != readingSettings.layout
        let marginsChanged = settings.hideMargins != readingSettings.hideMargins
        if marginsChanged && !settings.hideMargins { autoScales = true }
        readingSettings = settings
        if layoutChanged {
            displayDirection = settings.layout == .horizontal ? .horizontal : .vertical
            displayMode = settings.layout == .twoPages ? .twoUpContinuous : .singlePageContinuous
            layoutDocumentView()
        }
        if marginsChanged || layoutChanged { marginPage = nil }
        focusReadingPage()
    }

    func focusReadingPage() {
        guard readingSettings.hideMargins else {
            if marginPage != nil { marginPage = nil; autoScales = true }
            return
        }
        guard let page = currentPage, marginPage != ObjectIdentifier(page) || marginSize != bounds.size else { return }
        marginPage = ObjectIdentifier(page); marginSize = bounds.size
        guard let selection = page.selection(for:page.bounds(for:.cropBox)) else { return }
        let content = selection.bounds(for:page).insetBy(dx:-12,dy:-12).intersection(page.bounds(for:.cropBox))
        guard !content.isNull, content.width > 20, bounds.width > 0 else { return }
        autoScales = false; scaleFactor = min(maxScaleFactor,max(minScaleFactor,bounds.width/content.width))
        go(to:content,on:page)
    }

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
        scribbleDelegate.view = self
        addInteraction(UIIndirectScribbleInteraction(delegate:scribbleDelegate))
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
        pressurePreview.zPosition = 100
        pressurePreview.name = "pressure-preview"
        pressurePreview.actions = ["bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(pressurePreview)
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
        if configuredTool != tool || configuredScribble != acceptsScribble {
            cancelToolGesture()
            configuredTool = tool
            configuredScribble = acceptsScribble
            drawingPan.isEnabled = tool.capturesDrag && !(tool == .pen && workspace.convertHandwriting)
            annotationTap.isEnabled = [.move, .erase, .targetImage, .insertImage, .text, .note, .signature, .date, .checkmark, .cross, .stamp, .replaceText].contains(tool) || acceptsScribble
            let types: [UITouch.TouchType] = acceptsScribble ? [.direct,.indirectPointer] : [.direct,.indirectPointer,.stylus]
            drawingPan.allowedTouchTypes = types.map { NSNumber(value:$0.rawValue) }
            annotationTap.allowedTouchTypes = types.map { NSNumber(value:$0.rawValue) }
        }
        configureScrolling(drawing: drawingPan.isEnabled)
        selectionFrame.path = nil
        if tool == .move || tool.isShape, let annotation = workspace.selectedAnnotation, let page = annotation.page {
            let rect = convert(annotation.bounds, from: page)
            let outline = UIBezierPath(rect: rect)
            if !["Ink","Line","Widget"].contains(annotation.type ?? "") {
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
                else {
                    if workspace?.activeTool == .erase { eraseFrame() }
                    drawPreview()
                }
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
        pressurePreview.frame = bounds
        selectionFrame.frame = bounds
        keepFeedbackAbovePages()
        configureTool()
        layoutTextEntry()
        focusReadingPage()
    }

    private func keepFeedbackAbovePages() {
        let expected: [CALayer] = [preview, pressurePreview, selectionFrame] + (textInput.map { [$0.layer] } ?? [])
        let actual = Array(layer.sublayers?.suffix(expected.count) ?? [])
        guard actual.count != expected.count || zip(actual, expected).contains(where: { $0.0 !== $0.1 }) else { return }
        // PDFKit can insert opaque page views later. Preserve drawing order as well as depth.
        layer.addSublayer(preview)
        layer.addSublayer(pressurePreview)
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
        activateTool(at: gesture.location(in: self))
    }

    func activateTool(at location: CGPoint) {
        guard let workspace else { return }
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if workspace.activeTool == .replaceText, let selection = page.selectionForLine(at: point) {
            workspace.commitToolSelection(selection)
            return
        }
        if [.date,.checkmark,.cross,.stamp].contains(workspace.activeTool) {
            workspace.placeMark(workspace.activeTool, on: page, at: point)
            return
        }
        if workspace.activeTool == .insertImage {
            let crop = page.bounds(for:.cropBox), width = min(180,crop.width)
            let height = min(crop.height,width/max(0.1,workspace.insertionAspect))
            let rect = CGRect(x:min(max(point.x,crop.minX),crop.maxX-width),y:min(max(point.y-height,crop.minY),crop.maxY-height),width:width,height:height)
            workspace.regionTarget = AnnotationPlacement(page:page,bounds:rect,note:false)
            return
        }
        if workspace.activeTool == .targetImage {
            workspace.imageTarget = ContentImageTarget(page: document?.index(for: page) ?? 0, point: point)
            return
        }
        if workspace.activeTool == .text || workspace.activeTool == .note || (workspace.activeTool == .pen && workspace.convertHandwriting) {
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
        if workspace.activeTool == .erase {
            beginToolGesture(at: location)
            updateToolGesture(at: CGPoint(x: location.x+0.1,y:location.y))
            endToolGesture(at: location)
        }
        else { workspace.selectedAnnotation = hit }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            beginToolGesture(at: CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            for (point, force) in drawingPan.samples { updateToolGesture(at:point,pressure:force) }
            drawingPan.samples.removeAll()
            updateToolGesture(at: location)
        case .changed:
            for (point, force) in drawingPan.samples { updateToolGesture(at: point, pressure: force) }
            drawingPan.samples.removeAll()
            updateToolGesture(at: location)
        case .ended:
            for (point, force) in drawingPan.samples { updateToolGesture(at:point,pressure:force) }
            drawingPan.samples.removeAll()
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
        strokePressures = [nil]
        if workspace.activeTool == .erase { eraserBefore = page.annotations }
        let index = document?.index(for: page) ?? 0
        if workspace.pageIndex != index { workspace.pageIndex = index }
        if workspace.activeTool == .move {
            if let selected = workspace.selectedAnnotation, !["Ink","Line","Widget"].contains(selected.type ?? ""), selected.page === page {
                let bounds = convert(selected.bounds, from: page)
                resizing = hypot(origin.x - bounds.maxX, origin.y - bounds.maxY) < 22
                if resizing { movingAnnotation = selected }
            }
            if !resizing { movingAnnotation = page.annotations.reversed().first { $0.type != "Widget" && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) } }
            initialBounds = movingAnnotation?.bounds ?? .zero
            movingGroup = movingAnnotation.map { workspace.groupedAnnotations($0).map { ($0,$0.bounds) } } ?? []
            if workspace.selectedAnnotation !== movingAnnotation { workspace.selectedAnnotation = movingAnnotation }
        }
        previewDirty = true
        startFrames()
    }

    func updateToolGesture(at location: CGPoint, pressure: CGFloat? = nil) {
        guard let page = strokePage else { return }
        let box = page.bounds(for: .cropBox), point = convert(location, to: page)
        let clipped = CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
        if stroke.last == clipped { return }
        stroke.append(clipped)
        strokePressures.append(pressure ?? strokePressures.last ?? nil)
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
            for (item,rect) in movingGroup { item.bounds = rect }
            workspace.moveAnnotation(annotation, to: bounds)
        } else if workspace.activeTool == .erase, let before = eraserBefore {
            let after = page.annotations
            installAnnotations(before, on: page)
            workspace.replacePageAnnotations(on: page, before: before, after: after)
            eraserBefore = nil
        } else if workspace.activeTool.isInk {
            workspace.addInk(on: page, points: stroke, pressures: strokePressures, marker: workspace.activeTool == .freeHighlighter)
        } else if workspace.activeTool.isShape {
            workspace.addShape(on: page, from: stroke[0], to: stroke[stroke.count-1], tool: workspace.activeTool)
        } else if [.link,.redact].contains(workspace.activeTool), let first = stroke.first, let last = stroke.last {
            let rect = CGRect(x:min(first.x,last.x),y:min(first.y,last.y),width:abs(last.x-first.x),height:abs(last.y-first.y))
            if rect.width >= 4, rect.height >= 4 { workspace.regionTarget = AnnotationPlacement(page:page,bounds:rect,note:false) }
        }
    }

    private func installAnnotations(_ annotations: [PDFAnnotation], on page: PDFPage) {
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        for annotation in annotations { page.addAnnotation(annotation) }
        annotationsChanged(on: page)
    }

    private func eraseFrame() {
        guard let workspace, let page = strokePage, !stroke.isEmpty else { return }
        var touched = false
        let firstIndex = max(1,erasedPointCount)
        let segments: [(CGPoint,CGPoint)] = stroke.count == 1 ? [(stroke[0],stroke[0])] : (firstIndex..<stroke.count).map { (stroke[$0-1],stroke[$0]) }
        erasedPointCount = stroke.count
        for (from,to) in segments {
            var groupNames: Set<String> = []
            for annotation in page.annotations where annotation.type == "Ink" {
                let result = AnnotationGeometry.erase(annotation, from: from, to: to, radius:workspace.eraserSize, partial:workspace.eraserMode == .partial)
                guard result.changed else { continue }
                touched = true
                if workspace.eraserMode == .whole, let name = annotation.value(forAnnotationKey:.name) as? String, name.hasPrefix("PaperStudio-") {
                    groupNames.insert(name.split(separator:"-").dropLast().joined(separator:"-"))
                }
                page.removeAnnotation(annotation)
                if let replacement = result.replacement { page.addAnnotation(replacement) }
            }
            for annotation in page.annotations {
                if let name = annotation.value(forAnnotationKey:.name) as? String,
                   groupNames.contains(name.split(separator:"-").dropLast().joined(separator:"-")) { page.removeAnnotation(annotation) }
            }
        }
        if touched { annotationsChanged(on:page) }
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
        preview.fillColor = markup == .highlight ? UIColor(workspace.inkColor).withAlphaComponent(workspace.opacity).cgColor : UIColor.clear.cgColor
        preview.strokeColor = markup == .highlight ? UIColor.clear.cgColor : UIColor(workspace.inkColor).withAlphaComponent(workspace.opacity).cgColor
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
        preview.lineDashPattern = nil
        if workspace.activeTool == .erase {
            let point = convert(last,from:page), radius = workspace.eraserSize*scaleFactor
            preview.path = UIBezierPath(ovalIn:CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)).cgPath
            preview.strokeColor = UIColor.systemGray.cgColor
            preview.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
            preview.lineWidth = 1
            return
        }
        if workspace.activeTool == .move {
            guard let annotation = movingAnnotation else { return }
            let before = convert(annotation.bounds, from: page)
            let moved = movedBounds(on:page), dx = moved.minX-initialBounds.minX, dy = moved.minY-initialBounds.minY
            for (item,rect) in movingGroup { item.bounds = item === annotation ? moved : rect.offsetBy(dx:dx,dy:dy) }
            annotationsChanged(on: page)
            let after = convert(annotation.bounds, from: page)
            setNeedsDisplay(before.union(after).insetBy(dx: -4, dy: -4))
            path.append(UIBezierPath(rect: after))
        } else if workspace.activeTool == .pen && workspace.pressureSensitive && strokePressures.contains(where: { $0 != nil }) {
            drawPressurePreview(on: page)
            preview.path = nil
            return
        } else if workspace.activeTool.isInk {
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
            if workspace.activeTool == .line || workspace.activeTool == .arrow {
                path.append(AnnotationGeometry.linePath(from:convert(first,from:page),to:convert(last,from:page),arrow:workspace.activeTool == .arrow,double:workspace.shapeStyle.doubleArrow,width:workspace.lineWidth*scaleFactor))
            } else { path.append(workspace.activeTool == .oval ? UIBezierPath(ovalIn: viewRect) : UIBezierPath(rect: viewRect)) }
            preview.lineDashPattern = workspace.shapeStyle.pattern.dash.map { NSNumber(value:Double($0*scaleFactor)) }
        }
        preview.strokeColor = UIColor(workspace.inkColor).withAlphaComponent(workspace.opacity).cgColor
        preview.fillColor = workspace.activeTool == .redact ? UIColor.black.cgColor :
            (workspace.activeTool == .arrow || (workspace.activeTool.isShape && workspace.shapeStyle.filled) ? UIColor(workspace.inkColor).withAlphaComponent(workspace.opacity).cgColor : UIColor.clear.cgColor)
        preview.lineWidth = workspace.lineWidth * scaleFactor
        preview.path = path.cgPath
    }

    private func clearGesture() {
        stroke = []; strokePage = nil; gestureSelection = nil; movingAnnotation = nil; movingGroup = []; resizing = false; preview.path = nil
        penPath = UIBezierPath(); renderedPointCount = 0; previewDirty = false
        strokePressures = []; eraserBefore = nil; erasedPointCount = 0
        for band in pressureBands.values { band.path = nil }
    }

    func cancelToolGesture() {
        stopFrames()
        pendingSelection = false
        if let before = eraserBefore, let page = strokePage { installAnnotations(before,on:page) }
        if let annotation = movingAnnotation, let page = annotation.page {
            let before = convert(annotation.bounds, from: page)
            for (item,rect) in movingGroup { item.bounds = rect }
            annotationsChanged(on: page)
            setNeedsDisplay(before.union(convert(initialBounds, from: page)).insetBy(dx: -4, dy: -4))
        }
        if workspace?.activeTool.selectsText == true { clearSelection() }
        clearGesture()
    }

    private func drawPressurePreview(on page: PDFPage) {
        guard let workspace else { return }
        var paths: [Int:UIBezierPath] = [:]
        for i in 1..<stroke.count {
            let multiplier = strokePressures[i].map { 0.25 + min(1,max(0,$0))*1.75 } ?? 1
            let band = Int((multiplier*8).rounded())
            let path = paths[band] ?? UIBezierPath()
            path.move(to:convert(stroke[i-1],from:page)); path.addLine(to:convert(stroke[i],from:page)); paths[band] = path
        }
        for layer in pressureBands.values { layer.path = nil }
        for (band,path) in paths {
            let layer = pressureBands[band] ?? CAShapeLayer()
            if layer.superlayer == nil {
                layer.lineCap = .round; layer.lineJoin = .round; layer.fillColor = UIColor.clear.cgColor
                layer.contentsScale = UIScreen.main.scale
                layer.actions = ["path":NSNull(),"lineWidth":NSNull(),"strokeColor":NSNull(),"bounds":NSNull(),"position":NSNull()]
                pressurePreview.addSublayer(layer); pressureBands[band] = layer
            }
            layer.frame = pressurePreview.bounds
            layer.lineWidth = workspace.lineWidth*CGFloat(band)/8*scaleFactor
            layer.strokeColor = UIColor(workspace.inkColor).withAlphaComponent(workspace.opacity).cgColor
            layer.path = path.cgPath
        }
    }

    func isInlineTextInput(_ view: UIView) -> Bool { view === textInput }
    var isEditingText: Bool { textInput != nil }
    var acceptsScribble: Bool { workspace?.activeTool == .text || (workspace?.activeTool == .pen && workspace?.convertHandwriting == true) }

    func focusScribble(at point: CGPoint) -> UITextView? {
        guard acceptsScribble else { return nil }
        if let textInput { return textInput }
        guard let page = page(for:point,nearest:false) else { return nil }
        let rect = CGRect(x:point.x,y:point.y,width:220*scaleFactor,height:80*scaleFactor)
        if workspace?.activeTool == .pen, let color = workspace?.inkColor { workspace?.textStyle.color = color }
        beginTextEntry(on:page,bounds:convert(rect,to:page))
        return textInput
    }

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
        let bar = UIToolbar(); textBar = bar; barStyle = nil
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
        updateTextBar()
    }

    private func updateTextBar() {
        guard let bar = textBar, let workspace else { return }
        guard barStyle != workspace.textStyle else { return }
        barStyle = workspace.textStyle
        let familyMenu = UIMenu(children:TextFamily.allCases.map { family in
            UIAction(title:L10n.tr(family.title),state:workspace.textStyle.family == family ? .on : .off) { [weak workspace] _ in workspace?.textStyle.useFamily(family) }
        })
        let weightMenu = UIMenu(children:workspace.textStyle.availableWeights.map { weight in
            UIAction(title:L10n.tr(weight.title),state:workspace.textStyle.weight == weight ? .on : .off) { [weak workspace] _ in workspace?.textStyle.weight = weight }
        })
        let colors = UIMenu(children:ToolPalette.colors.enumerated().map { index,color in
            UIAction(title:L10n.tr(ToolPalette.names[index]),image:UIImage(systemName:"circle.fill")?.withTintColor(UIColor(color),renderingMode:.alwaysOriginal)) { [weak workspace] _ in workspace?.textStyle.color = color }
        })
        bar.items = [UIBarButtonItem(title:L10n.tr(workspace.textStyle.family.title),menu:familyMenu),
            UIBarButtonItem(title:L10n.tr(workspace.textStyle.weight.title),menu:weightMenu),
            UIBarButtonItem(title:"−",primaryAction:UIAction { [weak workspace] _ in if let workspace { workspace.textStyle.size = max(6,workspace.textStyle.size-1) } }),
            UIBarButtonItem(title:"\(Int(workspace.textStyle.size)) pt",style:.plain,target:nil,action:nil),
            UIBarButtonItem(title:"+",primaryAction:UIAction { [weak workspace] _ in if let workspace { workspace.textStyle.size = min(96,workspace.textStyle.size+1) } }),
            UIBarButtonItem(image:UIImage(systemName:"circle.fill")?.withTintColor(UIColor(workspace.textStyle.color),renderingMode:.alwaysOriginal),menu:colors),
            UIBarButtonItem(barButtonSystemItem:.flexibleSpace,target:nil,action:nil),
            UIBarButtonItem(barButtonSystemItem:.cancel,target:self,action:#selector(cancelTextEntry)),
            UIBarButtonItem(barButtonSystemItem:.done,target:self,action:#selector(finishTextEntry))]
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
        textInput = nil; textPlacement = nil; editedTextAnnotation = nil; initialTextStyle = nil; textBar = nil
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
        textInput = nil; textPlacement = nil; editedTextAnnotation = nil; initialTextStyle = nil; textBar = nil
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
