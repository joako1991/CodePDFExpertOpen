import SwiftUI
import PDFKit
import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case read, highlight, underline, strikeOut, text, note, signature, pen, rectangle, oval, move, erase, replaceText, targetImage
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
        case .rectangle: return "Rectangle"
        case .oval: return "Ellipse"
        case .move: return "Déplacer"
        case .erase: return "Effacer"
        case .replaceText: return "Remplacer le texte"
        case .targetImage: return "Remplacer une image"
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
        case .rectangle: return "rectangle"
        case .oval: return "oval"
        case .move: return "arrow.up.left.and.arrow.down.right"
        case .erase: return "eraser"
        case .replaceText: return "text.cursor"
        case .targetImage: return "photo.badge.arrow.down"
        }
    }
    var markup: PDFAnnotationSubtype? {
        switch self { case .highlight: return .highlight; case .underline: return .underline; case .strikeOut: return .strikeOut; default: return nil }
    }
    var selectsText: Bool { markup != nil || self == .replaceText }
    var defaultColor: Color {
        switch self { case .highlight: return .yellow; case .underline: return .blue; case .strikeOut: return .red; case .text, .signature: return .black; default: return .indigo }
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
    @Published var activeTool: CanvasTool = .read {
        didSet {
            guard oldValue != activeTool else { return }
            switchingTool = true
            inkColor = toolColors[activeTool] ?? activeTool.defaultColor
            switchingTool = false
            pdfView?.clearSelection()
            selectedAnnotation = nil
        }
    }
    @Published var inkColor: Color = .indigo {
        didSet { if !switchingTool { toolColors[activeTool] = inkColor } }
    }
    private var switchingTool = false
    private var toolColors: [CanvasTool: Color] = [:]
    @Published var textStyle = TextStyle()
    @Published var placement: AnnotationPlacement?
    @Published var textTarget: ContentTextTarget?
    var signatureStrokes: [[CGPoint]] = []
    var signatureSize: CGSize = .zero
    @Published var lineWidth: CGFloat = 2
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var bookmarks: Set<Int> = []
    @Published var imageTarget: ContentImageTarget?
    weak var pdfView: PDFView?
    private struct Snapshot { let data: Data; let pageIndex: Int; let bookmarks: Set<Int> }
    private var history: [Snapshot] = []
    private var future: [Snapshot] = []
    private var undoBytes = 0
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

    private func snapshot() throws -> Snapshot {
        guard let document, !document.isLocked, document.allowsDocumentChanges,
              let data = document.dataRepresentation() else { throw StudioError.writeFailed }
        return Snapshot(data: data, pageIndex: pageIndex, bookmarks: bookmarks)
    }

    private func pushHistory(_ snapshot: Snapshot) {
        history.append(snapshot)
        undoBytes += snapshot.data.count
        while history.count > 12 || (undoBytes > undoBudget && history.count > 1) {
            undoBytes -= history.removeFirst().data.count
        }
    }

    private func restore(_ snapshot: Snapshot) {
        guard let restored = PDFDocument(data: snapshot.data) else { return }
        if restored.isLocked, let openedPassword { _ = restored.unlock(withPassword: openedPassword) }
        document = restored
        pageIndex = min(snapshot.pageIndex, max(0, restored.pageCount - 1))
        bookmarks = snapshot.bookmarks
        selectedAnnotation = nil
        searchResults = []
        pdfView?.highlightedSelections = nil
        revision += 1
        dirty = true
    }

    func perform(_ operation: () throws -> Void) {
        do {
            let before = try snapshot()
            try operation()
            pushHistory(before)
            future = []
            dirty = true
            revision += 1
            status = "Modifications non enregistrées"
        } catch { self.error = error.localizedDescription }
    }

    func undo() {
        guard let before = history.last else { return }
        do {
            let current = try snapshot()
            history.removeLast()
            undoBytes -= before.data.count
            future.append(current)
            restore(before)
        } catch { self.error = error.localizedDescription }
    }

    func redo() {
        guard let next = future.last else { return }
        do {
            let current = try snapshot()
            future.removeLast()
            pushHistory(current)
            restore(next)
        } catch { self.error = error.localizedDescription }
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
        perform { annotation.widgetStringValue = value }
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
        let before = try snapshot()
        let previousRevision = revision
        let output = try await MuPDFEngine.processAsync(data: before.data, password: openedPassword ?? "",
            operation: operation, page: page, region: region, text: text, fontSize: fontSize, image: image)
        try Task.checkCancellation()
        guard revision == previousRevision else {
            throw MuPDFEngine.EngineError(message: "Le document a changé pendant le traitement. Réessayez l’opération.")
        }
        guard let updated = PDFDocument(data: output) else { throw StudioError.invalidPDF }
        if updated.isLocked {
            guard updated.unlock(withPassword: openedPassword ?? "") else { throw StudioError.invalidPDF }
        }
        pushHistory(before)
        future = []
        document = updated
        pageIndex = min(page, max(0, updated.pageCount - 1))
        selectedAnnotation = nil
        searchResults = []
        pdfView?.highlightedSelections = nil
        imageTarget = nil
        pdfView?.clearSelection()
        dirty = true
        revision += 1
        status = "Contenu PDF modifié avec MuPDF — enregistrez le document"
    }

    func exportWord() async throws -> URL {
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
        guard let target = document?.page(at: index) else { return }
        pageIndex = index
        pdfView?.go(to: target)
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
        let color = UIColor(inkColor).withAlphaComponent(type == .highlight ? 0.4 : 1)
        for line in selection.selectionsByLine() {
            for page in line.pages {
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
        perform {
            for (page, bounds) in additions {
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = color
                let border = PDFBorder(); border.lineWidth = lineWidth; annotation.border = border
                page.addAnnotation(annotation)
            }
        }
    }

    func commitToolSelection(_ selection: PDFSelection) {
        if let markup = activeTool.markup { applyMarkup(selection, type: markup) }
        else if activeTool == .replaceText, selection.pages.count == 1,
                selection.selectionsByLine().count == 1, let page = selection.pages.first,
                let document, let text = selection.string, !text.isEmpty {
            textTarget = ContentTextTarget(page: document.index(for: page), bounds: selection.bounds(for: page), text: text)
        }
    }

    func requestPlacement(on page: PDFPage, bounds: CGRect, note: Bool = false) {
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
        perform {
            let annotation = PDFAnnotation(bounds: placement.bounds, forType: placement.note ? .text : .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = textStyle.font
            annotation.fontColor = UIColor(textStyle.color)
            annotation.color = placement.note ? .systemYellow : .clear
            let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
            placement.page.addAnnotation(annotation)
            selectedAnnotation = annotation
        }
    }

    func readTextStyle(from annotation: PDFAnnotation) {
        guard let font = annotation.font else { return }
        textStyle.size = Double(font.pointSize)
        let name = font.familyName.lowercased()
        textStyle.family = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ? .monospaced :
            (name.contains("serif") || name.contains("newyork") || name.contains("times") ? .serif : .system)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        textStyle.weight = weight >= Double(UIFont.Weight.bold.rawValue) ? .bold :
            (weight >= Double(UIFont.Weight.semibold.rawValue) ? .semibold : (weight >= Double(UIFont.Weight.medium.rawValue) ? .medium : .regular))
        textStyle.color = Color(annotation.fontColor ?? .black)
    }

    func updateTextAnnotation(_ annotation: PDFAnnotation, text: String) {
        guard annotation.page?.document === document else { return }
        perform {
            annotation.contents = text
            if annotation.type == "FreeText" {
                annotation.font = textStyle.font
                annotation.fontColor = UIColor(textStyle.color)
            }
        }
    }

    func addDrawing(on page: PDFPage, points: [CGPoint], tool: CanvasTool) {
        guard points.count > 1 else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -lineWidth, dy: -lineWidth)
        perform {
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
            page.addAnnotation(annotation)
            selectedAnnotation = annotation
        }
    }

    func moveAnnotation(_ annotation: PDFAnnotation, to bounds: CGRect) {
        perform { annotation.bounds = bounds; selectedAnnotation = annotation }
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
        guard annotation.type != "Widget", let page = annotation.page else { return }
        perform { page.removeAnnotation(annotation); selectedAnnotation = nil }
    }

    func updateSelectedText(_ text: String) {
        guard let annotation = selectedAnnotation else { return }
        perform { annotation.contents = text }
    }

    func addText(_ text: String, note: Bool) {
        guard let page, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform {
            let box = page.bounds(for: .mediaBox)
            let width = min(260.0, box.width * 0.7)
            let annotation = PDFAnnotation(bounds: CGRect(x: box.midX - width / 2, y: box.midY, width: note ? 30 : width, height: note ? 30 : 100), forType: note ? .text : .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = .systemFont(ofSize: 16)
            annotation.fontColor = .black
            annotation.color = note ? .systemYellow : .clear
            page.addAnnotation(annotation)
        }
    }

    func addSignature(_ strokes: [[CGPoint]], size: CGSize, on targetPage: PDFPage? = nil, at point: CGPoint? = nil) {
        guard let page = targetPage ?? page, size.width > 0, size.height > 0, !strokes.isEmpty else { return }
        perform {
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
            page.addAnnotation(annotation)
        }
    }

    func rotate() { guard let page else { return }; perform { page.rotation = (page.rotation + 90) % 360 } }

    func deletePage() {
        guard let document else { return }
        guard document.pageCount > 1 else { error = StudioError.lastPage.localizedDescription; return }
        perform {
            document.removePage(at: pageIndex)
            bookmarks = Set(bookmarks.filter { $0 != pageIndex }.map { $0 > pageIndex ? $0 - 1 : $0 })
            pageIndex = min(pageIndex, document.pageCount - 1)
            selectedAnnotation = nil
        }
        go(to: pageIndex)
    }

    func movePage(by offset: Int) {
        guard let document, let page else { return }
        let target = pageIndex + offset
        guard (0..<document.pageCount).contains(target) else { return }
        perform {
            document.removePage(at: pageIndex)
            document.insert(page, at: target)
            let old = pageIndex
            bookmarks = Set(bookmarks.map { index in
                if index == old { return target }
                if old < target && index > old && index <= target { return index - 1 }
                if target < old && index >= target && index < old { return index + 1 }
                return index
            })
            pageIndex = target
        }
        go(to: target)
    }

    func merge(_ urls: [URL]) {
        perform {
            guard let document else { throw StudioError.invalidPDF }
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
            for page in additions { document.insert(page, at: document.pageCount) }
        }
    }

    func export(password: String? = nil, currentPageOnly: Bool = false) -> URL? {
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
        do {
            guard let document, !document.isLocked, document.allowsCopying else { throw StudioError.invalidPDF }
            return try PDFConversions.temporaryFile(data: Data((document.string ?? "").utf8), name: "\(url.deletingPathExtension().lastPathComponent).txt")
        } catch { self.error = error.localizedDescription; return nil }
    }

    func exportImage() -> URL? {
        do {
            guard let document, document.allowsCopying, let page,
                  let data = PDFConversions.image(of: page, quality: .detailed).pngData() else { throw StudioError.invalidPDF }
            return try PDFConversions.temporaryFile(data: data, name: L10n.format("Page %lld", pageIndex + 1) + ".png")
        } catch { self.error = error.localizedDescription; return nil }
    }
}
