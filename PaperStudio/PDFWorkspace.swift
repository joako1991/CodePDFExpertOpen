import SwiftUI
import PDFKit
import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case read, highlight, underline, strikeOut, text, note, signature, pen, freeHighlighter, rectangle, oval, line, arrow, move, erase, replaceText, targetImage, insertImage, link, redact, date, checkmark, cross, stamp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: return "Lire"
        case .highlight: return "Surligner"
        case .underline: return "Souligner"
        case .strikeOut: return "Barrer"
        case .text: return "Texte"
        case .note: return "Note"
        case .signature: return "Signer"
        case .pen: return "Dessiner"
        case .freeHighlighter: return "Marqueur libre"
        case .rectangle: return "Rectangle"
        case .oval: return "Ellipse"
        case .line: return "Ligne"
        case .arrow: return "Flèche"
        case .move: return "Déplacer"
        case .erase: return "Effacer"
        case .replaceText: return "Remplacer le texte"
        case .targetImage: return "Remplacer une image"
        case .insertImage: return "Insérer une image"
        case .link: return "Lien"
        case .redact: return "Biffer"
        case .date: return "Date"
        case .checkmark: return "Coche"
        case .cross: return "Croix"
        case .stamp: return "Tampon"
        }
    }
    var symbol: String {
        switch self {
        case .read: return "hand.draw"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .text: return "textformat"
        case .note: return "note.text.badge.plus"
        case .signature: return "signature"
        case .pen: return "pencil.tip"
        case .freeHighlighter: return "highlighter"
        case .rectangle: return "rectangle"
        case .oval: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .move: return "arrow.up.left.and.arrow.down.right"
        case .erase: return "eraser"
        case .replaceText: return "text.cursor"
        case .targetImage: return "photo.badge.arrow.down"
        case .insertImage: return "photo.badge.plus"
        case .link: return "link"
        case .redact: return "rectangle.fill"
        case .date: return "calendar"
        case .checkmark: return "checkmark"
        case .cross: return "xmark"
        case .stamp: return "seal"
        }
    }
    var markup: PDFAnnotationSubtype? {
        switch self { case .highlight: return .highlight; case .underline: return .underline; case .strikeOut: return .strikeOut; default: return nil }
    }
    var selectsText: Bool { markup != nil || self == .replaceText }
    var defaultColor: Color {
        switch self { case .highlight, .freeHighlighter: return .yellow; case .underline: return .blue; case .strikeOut, .rectangle, .oval, .line, .arrow: return .red; case .text, .pen, .signature, .date, .checkmark, .cross: return .black; case .stamp: return .red; default: return .indigo }
    }
}

struct ContentTextTarget: Identifiable {
    let id = UUID()
    let page: Int
    let bounds: CGRect
    let text: String
}

struct ContentImageTarget: Identifiable {
    let id = UUID()
    let page: Int
    let point: CGPoint
}

@MainActor
final class PDFWorkspace: ObservableObject {
    let url: URL
    @Published var document: PDFDocument?
    @Published var pageIndex = 0
    @Published var revision = 0
    @Published var error: String?
    @Published var status = ""
    @Published var dirty = false
    @Published var recognizing = false
    @Published var recognizedText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var editorMode: EditorMode = .annotate {
        didSet { if oldValue != editorMode { finishInteraction(); activeTool = .read; selectedAnnotation = nil } }
    }
    @Published var activeTool: CanvasTool = .read {
        didSet {
            guard oldValue != activeTool else { return }
            (pdfView as? DrawingPDFView)?.finishTextEntry()
            switchingTool = true
            inkColor = toolColors[styleKey] ?? activeTool.defaultColor
            lineWidth = toolWidths[styleKey] ?? activeTool.defaultWidth
            opacity = toolOpacities[styleKey] ?? ([.highlight,.freeHighlighter].contains(activeTool) ? 0.4 : 1)
            switchingTool = false
            pdfView?.clearSelection()
            selectedAnnotation = nil
            (pdfView as? DrawingPDFView)?.configureTool()
        }
    }
    @Published var inkColor: Color = .indigo {
        didSet { if !switchingTool { toolColors[styleKey] = inkColor } }
    }
    private var switchingTool = false
    private var toolColors: [CanvasTool: Color] = [:]
    private var toolWidths: [CanvasTool: CGFloat] = [:]
    private var toolOpacities: [CanvasTool: Double] = [:]
    private var styleKey: CanvasTool { activeTool.isShape ? .rectangle : activeTool }
    private var readingTextStyle = false
    @Published var textStyle = TextStyle() {
        didSet {
            let view = pdfView as? DrawingPDFView
            view?.updateTextEntryStyle()
            if !readingTextStyle, view?.isEditingText != true, activeTool == .text, selectedAnnotation?.type == "FreeText" {
                beginAppearanceEditing(); previewSelectedAppearance(); finishAppearanceEditing()
            }
        }
    }
    @Published var placement: AnnotationPlacement?
    @Published var textTarget: ContentTextTarget?
    var signatureStrokes: [[CGPoint]] = []
    var signatureSize: CGSize = .zero
    @Published var lineWidth: CGFloat = 2 { didSet { if !switchingTool { toolWidths[styleKey] = lineWidth } } }
    @Published var opacity: Double = 1 { didSet { if !switchingTool { toolOpacities[styleKey] = opacity } } }
    @Published var shapeStyle = AnnotationShapeStyle()
    @Published var eraserMode: EraserMode = .whole
    @Published var eraserSize: CGFloat = 14
    @Published var pressureSensitive = true
    @Published var convertHandwriting = false { didSet { (pdfView as? DrawingPDFView)?.configureTool() } }
    @Published var reading = ReadingSettings()
    @Published var panel: DocumentPanel = .pages
    @Published var stampText = L10n.tr("APPROUVÉ")
    @Published var stampDate = Date()
    @Published var regionTarget: AnnotationPlacement?
    var insertionImage: Data?
    var insertionAspect: CGFloat = 1
    @Published var processingDocument = false
    private var appearanceBefore: [AnnotationAppearance] = []
    private var appearanceWidth: CGFloat = 1
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var bookmarks: Set<Int> = []
    @Published var imageTarget: ContentImageTarget?
    weak var pdfView: PDFView?
    // Ordinary edits retain only what changed. Serializing the entire PDF here blocks input.
    private struct Edit {
        let pages: [PDFPage]
        let cost: Int
        let layout: Bool
        let undo: () -> Void
        let redo: () -> Void
    }
    private var history: [Edit] = []
    private var future: [Edit] = []
    private var undoBytes = 0
    let thumbnailNamespace = UUID()
    @Published private(set) var pageVersions: [ObjectIdentifier: Int] = [:]
    private var openedPassword: String?
    private let undoBudget = 64 * 1024 * 1024
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var page: PDFPage? { document?.page(at: pageIndex) }
    var hasFormFields: Bool {
        guard let document else { return false }
        return (0..<document.pageCount).contains { index in
            document.page(at: index)?.annotations.contains { $0.type == "Widget" } == true
        }
    }
    private var bookmarkURL: URL { url.appendingPathExtension("bookmarks.json") }

    init(url: URL) {
        self.url = url
        document = PDFDocument(url: url)
        if document == nil { error = StudioError.invalidPDF.localizedDescription }
        if let data = try? Data(contentsOf: bookmarkURL), let saved = try? JSONDecoder().decode([Int].self, from: data) {
            bookmarks = Set(saved.filter { (0..<(document?.pageCount ?? 0)).contains($0) })
        }
    }

    func unlock(_ password: String) {
        guard document?.unlock(withPassword: password) == true else {
            error = "Mot de passe incorrect."; return
        }
        openedPassword = password
        revision += 1
    }

    private var canEdit: Bool {
        document?.isLocked == false && document?.allowsDocumentChanges == true
    }

    private func pushHistory(_ edit: Edit) {
        history.append(edit)
        undoBytes += edit.cost
        while history.count > 100 || (undoBytes > undoBudget && history.count > 1) {
            undoBytes -= history.removeFirst().cost
        }
    }

    private func changed(_ pages: [PDFPage], layout: Bool) {
        var seen: Set<ObjectIdentifier> = []
        let pages = pages.filter { seen.insert(ObjectIdentifier($0)).inserted }
        var versions = pageVersions
        for page in pages { versions[ObjectIdentifier(page), default: 0] += 1 }
        pageVersions = versions
        dirty = true
        revision += 1
        status = "Modifications non enregistrées"
        // Invalidate only visible page regions; tool/settings changes do not repaint the PDF.
        if let view = pdfView {
            if layout {
                view.layoutDocumentView()
                if let page { view.go(to: page) }
            }
            for page in pages where page.document === view.document {
                view.annotationsChanged(on: page)
                view.setNeedsDisplay(view.convert(page.bounds(for: .cropBox), from: page))
            }
        }
    }

    private func commit(pages: [PDFPage], cost: Int = 1024, layout: Bool = false,
                        undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard canEdit else { error = StudioError.writeFailed.localizedDescription; return }
        let edit = Edit(pages: pages, cost: cost, layout: layout, undo: undo, redo: redo)
        edit.redo()
        pushHistory(edit)
        future.removeAll()
        changed(pages, layout: layout)
    }

    func undo() {
        (pdfView as? DrawingPDFView)?.finishTextEntry()
        guard canEdit, let edit = history.popLast() else { return }
        (pdfView as? DrawingPDFView)?.cancelToolGesture()
        pdfView?.clearSelection()
        selectedAnnotation = nil
        undoBytes -= edit.cost
        edit.undo()
        future.append(edit)
        changed(edit.pages, layout: edit.layout)
    }

    func redo() {
        (pdfView as? DrawingPDFView)?.finishTextEntry()
        guard canEdit, let edit = future.popLast() else { return }
        (pdfView as? DrawingPDFView)?.cancelToolGesture()
        pdfView?.clearSelection()
        selectedAnnotation = nil
        edit.redo()
        pushHistory(edit)
        changed(edit.pages, layout: edit.layout)
    }

    func addAnnotations(_ additions: [(PDFPage, PDFAnnotation)], cost: Int = 1024) {
        guard additions.allSatisfy({ $0.0.document === document }) else { return }
        guard !additions.isEmpty else { return }
        commit(pages: additions.map { $0.0 }, cost: max(cost, additions.count * 1024), undo: {
            for (page, annotation) in additions { page.removeAnnotation(annotation) }
        }, redo: {
            for (page, annotation) in additions { page.addAnnotation(annotation) }
        })
    }

    func replacePageAnnotations(on page: PDFPage, before: [PDFAnnotation], after: [PDFAnnotation]) {
        guard page.document === document else { return }
        let oldIDs = before.map(ObjectIdentifier.init), newIDs = after.map(ObjectIdentifier.init)
        guard oldIDs != newIDs else { return }
        func install(_ annotations: [PDFAnnotation]) {
            for annotation in page.annotations { page.removeAnnotation(annotation) }
            for annotation in annotations { page.addAnnotation(annotation) }
        }
        commit(pages: [page], cost: (before.count+after.count)*1024, undo: { install(before) }, redo: { install(after) })
        selectedAnnotation = nil
    }

    func beginAppearanceEditing() {
        finishAppearanceEditing()
        if let annotation = selectedAnnotation, activeTool.isShape || activeTool == .move || activeTool == .text {
            appearanceBefore = groupedAnnotations(annotation).map(AnnotationAppearance.init)
            appearanceWidth = max(0.01,lineWidth)
        }
    }

    func previewSelectedAppearance() {
        guard let annotation = selectedAnnotation, let page = annotation.page, page.document === document,
              activeTool.isShape || activeTool == .move || activeTool == .text else { return }
        for annotation in groupedAnnotations(annotation) {
        if annotation.type == "FreeText" {
            guard (pdfView as? DrawingPDFView)?.isEditingText != true else { return }
            annotation.font = textStyle.font; annotation.fontColor = UIColor(textStyle.color)
        } else {
            annotation.color = UIColor(inkColor).withAlphaComponent(opacity)
            if annotation.type == "Square" || annotation.type == "Circle" { annotation.interiorColor = shapeStyle.filled ? annotation.color : .clear }
            let border = PDFBorder()
            if annotation.type == "Ink", let before = appearanceBefore.first(where: { $0.annotation === annotation }) {
                border.lineWidth = (before.border?.lineWidth ?? lineWidth)*lineWidth/appearanceWidth
            } else { border.lineWidth = lineWidth }
            border.style = shapeStyle.pattern == .solid ? .solid : .dashed
            border.dashPattern = shapeStyle.pattern.dash.map { NSNumber(value:Double($0)) }; annotation.border = border
            if annotation.type == "Line", annotation.endLineStyle == .closedArrow {
                annotation.startLineStyle = shapeStyle.doubleArrow ? .closedArrow : .none
                annotation.interiorColor = annotation.color
            }
        }
        }
        pdfView?.annotationsChanged(on:page)
    }

    func finishAppearanceEditing() {
        let before = appearanceBefore
        appearanceBefore = []
        let after = before.map { AnnotationAppearance($0.annotation) }
        guard before != after, let page = before.first?.annotation.page, page.document === document else { return }
        for state in before { state.restore() }
        commit(pages:[page],undo:{for state in before { state.restore() }},redo:{for state in after { state.restore() }})
    }

    func selectAnnotation(_ annotation: PDFAnnotation) {
        finishInteraction()
        guard let page = annotation.page, page.document === document else { return }
        if !editorMode.tools.contains(.move) { editorMode = .annotate }
        activeTool = .move; selectedAnnotation = annotation
        inkColor = Color(annotation.color.withAlphaComponent(1)); opacity = Double(annotation.color.cgColor.alpha)
        lineWidth = annotation.border?.lineWidth ?? 2
        if let name = annotation.value(forAnnotationKey:.name) as? String, name.hasPrefix("PaperStudio-"),
           let band = name.split(separator:"-").last.flatMap({Int($0)}), band > 0 {
            lineWidth = lineWidth*8/CGFloat(band)
        }
        shapeStyle.pattern = annotation.border?.style == .dashed ? .dashed : .solid
        shapeStyle.filled = (annotation.interiorColor?.cgColor.alpha ?? 0) > 0
        if annotation.type == "FreeText" { readTextStyle(from:annotation) }
        pdfView?.go(to:annotation.bounds.insetBy(dx:-20,dy:-20),on:page)
    }

    func toggleBookmark() {
        if bookmarks.contains(pageIndex) { bookmarks.remove(pageIndex) } else { bookmarks.insert(pageIndex) }
        if !dirty { persistBookmarks() }
    }

    func markExternalChange() {
        dirty = true
        status = "Formulaire modifié — enregistrez le document"
    }

    func setFormValue(_ annotation: PDFAnnotation, value: String) {
        guard annotation.type == "Widget", annotation.widgetFieldType == .text || annotation.widgetFieldType == .choice,
              !annotation.isReadOnly else { return }
        guard let page = annotation.page, page.document === document, annotation.widgetStringValue != value else { return }
        let before = annotation.widgetStringValue
        commit(pages: [page], undo: { annotation.widgetStringValue = before },
               redo: { annotation.widgetStringValue = value })
    }

    func selectedTextTarget() throws -> ContentTextTarget {
        guard let selection = pdfView?.currentSelection, selection.pages.count == 1,
              selection.selectionsByLine().count == 1, let page = selection.pages.first,
              let document, let text = selection.string, !text.isEmpty else {
            throw MuPDFEngine.EngineError(message: "Sélectionnez une seule ligne de texte sur une page, puis choisissez Remplacer le texte.")
        }
        return ContentTextTarget(page: document.index(for: page), bounds: selection.bounds(for: page), text: text)
    }

    func replaceContent(operation: MuPDFEngine.Operation, page: Int, region: CGRect,
                        text: String = "", fontSize: Float = 12, image: Data = Data()) async throws {
        finishInteraction()
        guard let before = document, canEdit, let data = before.dataRepresentation() else { throw StudioError.writeFailed }
        let oldIndex = pageIndex
        let previousRevision = revision
        let output = try await MuPDFEngine.processAsync(data: data, password: openedPassword ?? "",
            operation: operation, page: page, region: region, text: text, fontSize: fontSize, image: image)
        try Task.checkCancellation()
        guard revision == previousRevision else {
            throw MuPDFEngine.EngineError(message: "Le document a changé pendant le traitement. Réessayez l’opération.")
        }
        guard let updated = PDFDocument(data: output) else { throw StudioError.invalidPDF }
        if updated.isLocked {
            guard updated.unlock(withPassword: openedPassword ?? "") else { throw StudioError.invalidPDF }
        }
        commit(pages: [], cost: data.count + output.count, undo: { [weak self] in
            self?.installDocument(before, pageIndex: oldIndex)
        }, redo: { [weak self] in
            self?.installDocument(updated, pageIndex: page)
        })
        imageTarget = nil
        status = "Contenu PDF modifié avec MuPDF — enregistrez le document"
    }

    private func installDocument(_ document: PDFDocument, pageIndex: Int) {
        (pdfView as? DrawingPDFView)?.cancelToolGesture()
        pdfView?.clearSelection()
        self.document = document
        self.pageIndex = min(pageIndex, max(0, document.pageCount - 1))
        selectedAnnotation = nil
        searchResults = []
        pdfView?.highlightedSelections = nil
    }

    func exportWord() async throws -> URL {
        finishInteraction()
        guard let document, !document.isLocked, let data = document.dataRepresentation() else { throw StudioError.invalidPDF }
        let output = try await MuPDFEngine.processAsync(data: data, password: openedPassword ?? "", operation: .docx)
        try Task.checkCancellation()
        return try PDFConversions.temporaryFile(data: output, name: "\(url.deletingPathExtension().lastPathComponent).docx")
    }

    private func persistBookmarks() {
        do {
            try JSONEncoder().encode(bookmarks.sorted()).write(to: bookmarkURL, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func save() -> Bool {
        finishInteraction()
        do {
            guard let document, !document.isLocked else { throw StudioError.writeFailed }
            var options: [PDFDocumentWriteOption: Any] = [:]
            if document.isEncrypted {
                guard let openedPassword else { throw StudioError.writeFailed }
                options[.userPasswordOption] = openedPassword
                options[.ownerPasswordOption] = UUID().uuidString
            }
            guard let data = document.dataRepresentation(options: options) else { throw StudioError.writeFailed }
            // Atomic replacement leaves the prior file intact if writing fails.
            try data.write(to: url, options: .atomic)
            dirty = false
            persistBookmarks()
            status = "Enregistré sur cet iPad"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func go(to index: Int) {
        finishInteraction()
        guard let target = document?.page(at: index) else { return }
        pageIndex = index
        pdfView?.go(to: target)
    }

    func finishInteraction() {
        finishAppearanceEditing()
        (pdfView as? DrawingPDFView)?.finishTextEntry()
        (pdfView as? DrawingPDFView)?.cancelToolGesture()
    }

    func search(_ text: String) {
        searchResults = text.isEmpty ? [] : document?.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        pdfView?.highlightedSelections = searchResults
    }

    func highlight() {
        markup(.highlight)
    }

    func toggleTool(_ tool: CanvasTool) {
        activeTool = activeTool == tool ? .read : tool
    }

    func markup(_ type: PDFAnnotationSubtype) {
        guard let selection = pdfView?.currentSelection else { return }
        applyMarkup(selection, type: type)
    }

    func applyMarkup(_ selection: PDFSelection, type: PDFAnnotationSubtype) {
        guard !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var additions: [(PDFPage, CGRect)] = []
        let color = UIColor(inkColor).withAlphaComponent(opacity)
        for line in selection.selectionsByLine() {
            for page in line.pages {
                guard page.document === document else { continue }
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let duplicate = page.annotations.contains {
                    $0.type == type.rawValue.replacingOccurrences(of: "/", with: "") &&
                    $0.bounds == bounds
                }
                if !duplicate { additions.append((page, bounds)) }
            }
        }
        guard !additions.isEmpty else { return }
        addAnnotations(additions.map { page, bounds in
            let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            annotation.color = color
            let border = PDFBorder(); border.lineWidth = lineWidth; annotation.border = border
            return (page, annotation)
        })
    }

    func commitToolSelection(_ selection: PDFSelection) {
        if let markup = activeTool.markup { applyMarkup(selection, type: markup) }
        else if activeTool == .replaceText, selection.pages.count == 1,
                selection.selectionsByLine().count == 1, let page = selection.pages.first,
                let document, page.document === document, let text = selection.string, !text.isEmpty {
            textTarget = ContentTextTarget(page: document.index(for: page), bounds: selection.bounds(for: page), text: text)
        }
    }

    func requestPlacement(on page: PDFPage, bounds: CGRect, note: Bool = false) {
        guard page.document === document else { return }
        let clipped = bounds.standardized.intersection(page.bounds(for: .cropBox))
        guard !clipped.isNull, clipped.width >= 12, clipped.height >= 12 else {
            status = "Sélectionnez une zone plus grande pour le texte."
            return
        }
        placement = AnnotationPlacement(page: page, bounds: clipped, note: note)
    }

    func placeText(_ text: String, at placement: AnnotationPlacement) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              placement.page.document === document else { return }
        let annotation = PDFAnnotation(bounds: placement.bounds, forType: placement.note ? .text : .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = textStyle.font
        annotation.fontColor = UIColor(textStyle.color)
        annotation.color = placement.note ? .systemYellow : .clear
        let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
        addAnnotations([(placement.page, annotation)], cost: 1024 + text.utf8.count)
        if annotation.page != nil { selectedAnnotation = annotation }
    }

    func readTextStyle(from annotation: PDFAnnotation) {
        readingTextStyle = true
        defer { readingTextStyle = false }
        guard let font = annotation.font else { return }
        textStyle.size = Double(font.pointSize)
        let name = font.familyName.lowercased()
        textStyle.family = name.contains("helvetica") ? .helvetica : font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ? .monospaced :
            (name.contains("serif") || name.contains("newyork") || name.contains("times") || name.contains("georgia") ? .serif : .system)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        textStyle.weight = weight >= Double(UIFont.Weight.bold.rawValue) ? .bold :
            (weight >= Double(UIFont.Weight.semibold.rawValue) ? .semibold : (weight >= Double(UIFont.Weight.medium.rawValue) ? .medium : .regular))
        if !textStyle.availableWeights.contains(textStyle.weight) {
            textStyle.weight = textStyle.weight == .medium ? .regular : .bold
        }
        textStyle.color = Color(annotation.fontColor ?? .black)
    }

    func updateTextAnnotation(_ annotation: PDFAnnotation, text: String) {
        guard let page = annotation.page, page.document === document else { return }
        let before = (annotation.contents, annotation.font, annotation.fontColor)
        let font = textStyle.font, color = UIColor(textStyle.color)
        commit(pages: [page], cost: 1024 + text.utf8.count + (before.0?.utf8.count ?? 0), undo: {
            annotation.contents = before.0
            annotation.font = before.1
            annotation.fontColor = before.2
        }, redo: {
            annotation.contents = text
            if annotation.type == "FreeText" {
                annotation.font = font
                annotation.fontColor = color
            }
        })
    }

    func addDrawing(on page: PDFPage, points: [CGPoint], tool: CanvasTool) {
        guard page.document === document, points.count > 1 else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -lineWidth, dy: -lineWidth)
        let subtype: PDFAnnotationSubtype = tool == .pen ? .ink : (tool == .oval ? .circle : .square)
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = UIColor(inkColor)
        let border = PDFBorder(); border.lineWidth = lineWidth; annotation.border = border
        if tool == .pen {
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
            }
            annotation.add(path)
        }
        addAnnotations([(page, annotation)], cost: 1024 + points.count * MemoryLayout<CGPoint>.stride)
        if annotation.page != nil { selectedAnnotation = annotation }
    }

    func moveAnnotation(_ annotation: PDFAnnotation, to bounds: CGRect) {
        guard let page = annotation.page, page.document === document, annotation.bounds != bounds else { return }
        let before = annotation.bounds
        let group = groupedAnnotations(annotation).map { ($0,$0.bounds) }
        let dx = bounds.minX-before.minX, dy = bounds.minY-before.minY
        commit(pages: [page], undo: { for (item,rect) in group { item.bounds = rect } }, redo: {
            for (item,rect) in group { item.bounds = item === annotation ? bounds : rect.offsetBy(dx:dx,dy:dy) }
        })
        selectedAnnotation = annotation
    }

    func resizeSelected(by factor: CGFloat) {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }
        // Ink paths use annotation-local coordinates; resizing just their bounds would clip strokes.
        guard annotation.type != "Ink" else {
            error = "Les dessins et signatures peuvent être déplacés. Leur redimensionnement n’est pas encore disponible."
            return
        }
        let box = page.bounds(for: .cropBox)
        var bounds = annotation.bounds
        bounds.size = CGSize(width: min(box.width, max(12, bounds.width * factor)), height: min(box.height, max(12, bounds.height * factor)))
        bounds.origin.x = min(max(bounds.minX, box.minX), box.maxX - bounds.width)
        bounds.origin.y = min(max(bounds.minY, box.minY), box.maxY - bounds.height)
        moveAnnotation(annotation, to: bounds)
    }

    func removeAnnotation(_ annotation: PDFAnnotation) {
        guard annotation.type != "Widget", let page = annotation.page, page.document === document else { return }
        let group = groupedAnnotations(annotation)
        if group.count > 1 {
            let ids = Set(group.map(ObjectIdentifier.init))
            replacePageAnnotations(on:page,before:page.annotations,after:page.annotations.filter { !ids.contains(ObjectIdentifier($0)) })
            return
        }
        // Preserve stacking order when undoing deletion, without copying page contents.
        let following = Array(page.annotations.drop(while: { $0 !== annotation }).dropFirst())
        commit(pages: [page], undo: {
            for item in following { page.removeAnnotation(item) }
            page.addAnnotation(annotation)
            for item in following { page.addAnnotation(item) }
        }, redo: { page.removeAnnotation(annotation) })
        selectedAnnotation = nil
    }

    func updateSelectedText(_ text: String) {
        guard let annotation = selectedAnnotation, let page = annotation.page, page.document === document,
              annotation.contents != text else { return }
        let before = annotation.contents
        commit(pages: [page], undo: { annotation.contents = before }, redo: { annotation.contents = text })
    }

    func addText(_ text: String, note: Bool) {
        guard let page, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let box = page.bounds(for: .mediaBox)
        let width = min(260.0, box.width * 0.7)
        let annotation = PDFAnnotation(bounds: CGRect(x: box.midX - width / 2, y: box.midY, width: note ? 30 : width, height: note ? 30 : 100), forType: note ? .text : .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = .systemFont(ofSize: 16)
        annotation.fontColor = .black
        annotation.color = note ? .systemYellow : .clear
        addAnnotations([(page, annotation)], cost: 1024 + text.utf8.count)
    }

    func addSignature(_ strokes: [[CGPoint]], size: CGSize, on targetPage: PDFPage? = nil, at point: CGPoint? = nil) {
        guard let page = targetPage ?? page, page.document === document,
              size.width > 0, size.height > 0, strokes.contains(where: { $0.count > 1 }) else { return }
        let box = page.bounds(for: .cropBox)
        let width = min(240.0, box.width * 0.7)
        let height = min(box.height, width * size.height / size.width)
        let anchor = point ?? CGPoint(x: box.midX - width / 2, y: box.midY + height / 2)
        let x = min(max(anchor.x, box.minX), box.maxX - width)
        let y = min(max(anchor.y - height, box.minY), box.maxY - height)
        let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: width, height: height), forType: .ink, withProperties: nil)
        annotation.color = .black
        let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
        for stroke in strokes where stroke.count > 1 {
            let path = UIBezierPath()
            for (index, point) in stroke.enumerated() {
                let mapped = CGPoint(x: point.x / size.width * width, y: (1 - point.y / size.height) * height)
                if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
            }
            annotation.add(path)
        }
        addAnnotations([(page, annotation)], cost: 1024 + strokes.reduce(0) { $0 + $1.count * MemoryLayout<CGPoint>.stride })
    }

    func rotate() {
        finishInteraction()
        guard let page else { return }
        let before = page.rotation
        commit(pages: [page], layout: true, undo: { page.rotation = before }, redo: { page.rotation = (before + 90) % 360 })
    }

    func deletePage() {
        finishInteraction()
        guard let document, let removed = page else { return }
        guard document.pageCount > 1 else { error = StudioError.lastPage.localizedDescription; return }
        let index = pageIndex, beforeBookmarks = bookmarks
        commit(pages: [], layout: true, undo: { [weak self] in
            document.insert(removed, at: index)
            self?.bookmarks = beforeBookmarks
            self?.pageIndex = index
        }, redo: { [weak self] in
            document.removePage(at: index)
            self?.bookmarks = Set(beforeBookmarks.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
            self?.pageIndex = min(index, document.pageCount - 1)
            self?.selectedAnnotation = nil
        })
        go(to: pageIndex)
    }

    func movePage(by offset: Int) {
        finishInteraction()
        guard let document, let page else { return }
        let target = pageIndex + offset
        guard (0..<document.pageCount).contains(target) else { return }
        let old = pageIndex, beforeBookmarks = bookmarks
        commit(pages: [], layout: true, undo: { [weak self] in
            document.removePage(at: target)
            document.insert(page, at: old)
            self?.bookmarks = beforeBookmarks
            self?.pageIndex = old
        }, redo: { [weak self] in
            document.removePage(at: old)
            document.insert(page, at: target)
            self?.bookmarks = Set(beforeBookmarks.map { index in
                if index == old { return target }
                if old < target && index > old && index <= target { return index - 1 }
                if target < old && index >= target && index < old { return index + 1 }
                return index
            })
            self?.pageIndex = target
        })
        go(to: target)
    }

    func merge(_ urls: [URL]) {
        finishInteraction()
        do {
            guard let document, canEdit else { throw StudioError.invalidPDF }
            var additions: [PDFPage] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let other = PDFDocument(url: url), !other.isLocked else { throw StudioError.invalidPDF }
                for index in 0..<other.pageCount {
                    guard let page = other.page(at: index)?.copy() as? PDFPage else { throw StudioError.invalidPDF }
                    additions.append(page)
                }
            }
            guard !additions.isEmpty else { return }
            let first = document.pageCount
            commit(pages: [], layout: true, undo: {
                for _ in additions { document.removePage(at: first) }
            }, redo: {
                for (offset, page) in additions.enumerated() { document.insert(page, at: first + offset) }
            })
        } catch { self.error = error.localizedDescription }
    }

    func export(password: String? = nil, currentPageOnly: Bool = false) -> URL? {
        finishInteraction()
        do {
            guard let document, !document.isLocked else { throw StudioError.invalidPDF }
            let output: PDFDocument
            if currentPageOnly {
                guard let copy = page?.copy() as? PDFPage else { throw StudioError.invalidPDF }
                output = PDFDocument(); output.insert(copy, at: 0)
            } else {
                guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { throw StudioError.invalidPDF }
                output = copy
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(currentPageOnly ? L10n.format("Page %lld", pageIndex + 1) + ".pdf" : url.lastPathComponent)
            var options: [PDFDocumentWriteOption: Any] = [:]
            if let password, !password.isEmpty {
                options[.userPasswordOption] = password
                options[.ownerPasswordOption] = UUID().uuidString
            }
            guard let data = output.dataRepresentation(options: options) else { throw StudioError.writeFailed }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch { self.error = error.localizedDescription; return nil }
    }

    func recognizeCurrentPage() {
        guard let page, !recognizing else { return }
        recognizing = true
        recognizedText = ""
        let image = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
        guard let cgImage = image.cgImage else { recognizing = false; return }
        Task {
            do {
                let text = try await OCRService.lines(in: cgImage).map(\.text).joined(separator: "\n")
                recognizedText = text
                status = text.isEmpty ? "Aucun texte détecté" : "Texte reconnu — prêt à copier"
            } catch { self.error = error.localizedDescription }
            recognizing = false
        }
    }

    func exportText() -> URL? {
        finishInteraction()
        do {
            guard let document, !document.isLocked, document.allowsCopying else { throw StudioError.invalidPDF }
            return try PDFConversions.temporaryFile(data: Data((document.string ?? "").utf8), name: "\(url.deletingPathExtension().lastPathComponent).txt")
        } catch { self.error = error.localizedDescription; return nil }
    }

    func exportImage() -> URL? {
        finishInteraction()
        do {
            guard let document, document.allowsCopying, let page,
                  let data = PDFConversions.image(of: page, quality: .detailed).pngData() else { throw StudioError.invalidPDF }
            return try PDFConversions.temporaryFile(data: data, name: L10n.format("Page %lld", pageIndex + 1) + ".png")
        } catch { self.error = error.localizedDescription; return nil }
    }
}
