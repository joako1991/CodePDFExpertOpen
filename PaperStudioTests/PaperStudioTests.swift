import XCTest
import PDFKit
import Combine
import SwiftUI
@testable import PaperStudio

private final class SerializationTrackingDocument: PDFDocument {
    var serializations = 0
    override func dataRepresentation() -> Data? {
        serializations += 1
        return super.dataRepresentation()
    }
}

private final class ThreadTrackingPage: PDFPage {
    var renderedOnMainThread = true
    var renderCount = 0
    override func thumbnail(of size: CGSize, for box: PDFDisplayBox) -> UIImage {
        renderedOnMainThread = Thread.isMainThread
        renderCount += 1
        return super.thumbnail(of: size, for: box)
    }
}

@MainActor
final class PaperStudioTests: XCTestCase {
    var folder: URL!
    var library: DocumentLibrary!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = DocumentLibrary(directory: folder)
    }

    override func tearDown() async throws {
        library = nil
        try FileManager.default.removeItem(at: folder)
    }

    func testCreateAndReopenRealPDF() throws {
        let url = try library.createWelcome()
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Paper Studio") == true)
        XCTAssertEqual(library.documents.count, 1)
    }

    func testImportNeverOverwritesAnExistingDocument() throws {
        let source = try library.createWelcome()
        let original = try Data(contentsOf: source)
        let imported = try library.importPDF(source)
        XCTAssertNotEqual(source, imported)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(library.documents.count, 2)
    }

    func testInvalidImportDoesNotCreateLibraryEntry() throws {
        let invalid = folder.appendingPathComponent("broken.txt")
        try Data("not a PDF".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.importPDF(invalid))
        XCTAssertTrue(library.documents.isEmpty)
    }

    func testAnnotationSurvivesSaveAndReopen() throws {
        let url = try library.createWelcome()
        let workspace = PDFWorkspace(url: url)
        workspace.addText("Review this paragraph", note: true)
        XCTAssertTrue(workspace.dirty)
        XCTAssertTrue(workspace.save())
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.contents == "Review this paragraph" } == true)
        XCTAssertFalse(workspace.dirty)
    }

    func testUndoRestoresPriorPageRotation() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let original = workspace.page?.rotation
        workspace.rotate()
        XCTAssertNotEqual(workspace.page?.rotation, original)
        workspace.undo()
        XCTAssertEqual(workspace.page?.rotation, original)
    }

    func testCannotDeleteLastPage() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.deletePage()
        XCTAssertEqual(workspace.document?.pageCount, 1)
        XCTAssertNotNil(workspace.error)
    }

    func testMergeReorderDeleteAndExtract() throws {
        let first = try library.createWelcome()
        let second = try library.createWelcome()
        let workspace = PDFWorkspace(url: first)
        workspace.merge([second])
        XCTAssertEqual(workspace.document?.pageCount, 2)
        workspace.rotate()
        workspace.movePage(by: 1)
        XCTAssertEqual(workspace.pageIndex, 1)
        XCTAssertEqual(workspace.page?.rotation, 90)
        let extracted = try XCTUnwrap(workspace.export(currentPageOnly: true))
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        XCTAssertEqual(PDFDocument(url: extracted)?.pageCount, 1)
        workspace.deletePage()
        XCTAssertEqual(workspace.document?.pageCount, 1)
        XCTAssertEqual(PDFDocument(url: second)?.pageCount, 1)
    }

    func testProtectedExportRequiresPasswordAndPreservesOriginal() throws {
        let url = try library.createWelcome()
        let original = try Data(contentsOf: url)
        let workspace = PDFWorkspace(url: url)
        let exported = try XCTUnwrap(workspace.export(password: "test-passphrase"))
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let protected = try XCTUnwrap(PDFDocument(url: exported))
        XCTAssertTrue(protected.isLocked)
        XCTAssertFalse(protected.unlock(withPassword: "wrong"))
        XCTAssertTrue(protected.unlock(withPassword: "test-passphrase"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSearchFindsRealDocumentText() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.search("Paper Studio")
        XCTAssertFalse(workspace.searchResults.isEmpty)
        workspace.search("")
        XCTAssertTrue(workspace.searchResults.isEmpty)
    }

    func testSignatureProducesPersistedInkAnnotation() throws {
        let url = try library.createWelcome()
        let workspace = PDFWorkspace(url: url)
        workspace.addSignature([[CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 40), CGPoint(x: 80, y: 10)]], size: CGSize(width: 100, height: 50))
        XCTAssertTrue(workspace.save())
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertTrue(page.annotations.contains { $0.type == "Ink" })
    }

    func testRedoRestoresChangesAndNewEditInvalidatesRedo() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.rotate()
        workspace.undo()
        XCTAssertTrue(workspace.canRedo)
        workspace.redo()
        XCTAssertEqual(workspace.page?.rotation, 90)
        workspace.undo()
        workspace.addText("New branch", note: true)
        XCTAssertFalse(workspace.canRedo)
    }

    func testFailedMergeDoesNotLeaveUndoEntryOrPartialPages() throws {
        let source = try library.createWelcome()
        let workspace = PDFWorkspace(url: source)
        workspace.merge([source, folder.appendingPathComponent("missing.pdf")])
        XCTAssertEqual(workspace.document?.pageCount, 1)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertFalse(workspace.dirty)
        XCTAssertNotNil(workspace.error)
    }

    func testBookmarksFollowPagesAcrossMoveDeleteAndUndo() throws {
        let url = try library.createWelcome()
        let workspace = PDFWorkspace(url: url)
        workspace.merge([url])
        workspace.toggleBookmark()
        workspace.movePage(by: 1)
        XCTAssertEqual(workspace.bookmarks, [1])
        workspace.deletePage()
        XCTAssertTrue(workspace.bookmarks.isEmpty)
        workspace.undo()
        XCTAssertEqual(workspace.bookmarks, [1])
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(PDFWorkspace(url: url).bookmarks, [1])
    }

    func testDrawingCanMoveAndBeDeletedThenRestored() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let page = try XCTUnwrap(workspace.page)
        workspace.addDrawing(on: page, points: [CGPoint(x: 40, y: 80), CGPoint(x: 150, y: 200)], tool: .rectangle)
        let annotation = try XCTUnwrap(workspace.selectedAnnotation)
        let moved = annotation.bounds.offsetBy(dx: 20, dy: 10)
        workspace.moveAnnotation(annotation, to: moved)
        XCTAssertEqual(annotation.bounds, moved)
        workspace.removeAnnotation(annotation)
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.undo()
        XCTAssertEqual(workspace.page?.annotations.count, 1)
    }

    func testImagesBecomeSeparatePDFPages() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let url = try library.createFromImages([image, image])
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
        XCTAssertThrowsError(try PDFConversions.fromImages([]))
    }

    func testMaskBurnsBlackPixelsIntoNewImage() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let masked = PDFConversions.burnedImage(source, regions: [MaskedRegion(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))])
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        pixels.initialize(repeating: 0, count: 4)
        defer { pixels.deinitialize(count: 4); pixels.deallocate() }
        let context = try XCTUnwrap(CGContext(data: pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(masked.cgImage), in: CGRect(x: -50, y: -50, width: 100, height: 100))
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[1], 0)
        XCTAssertEqual(pixels[2], 0)
        XCTAssertEqual(pixels[3], 255)
        XCTAssertNotEqual(masked.pngData(), source.pngData())
    }

    func testMaskedCopyContainsNoOriginalTextAnnotationsOrMetadata() throws {
        let url = try library.createWelcome()
        let original = try Data(contentsOf: url)
        let workspace = PDFWorkspace(url: url)
        workspace.addText("secret-note", note: true)
        let document = try XCTUnwrap(workspace.document)
        document.documentAttributes = [PDFDocumentAttribute.authorAttribute: "private-author"]
        let data = try PDFConversions.rasterized(document, quality: .compact,
                                               masks: [0: [MaskedRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))]])
        let output = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(output.pageCount, document.pageCount)
        XCTAssertTrue((output.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(output.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertNotEqual(output.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "private-author")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSearchablePDFEmbedsRecognizedTextInTextLayer() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        let line = RecognizedLine(text: "Searchable invoice 12345", bounds: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.05))
        let data = OCRService.pageData(image: image, size: image.size, lines: [line])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(pdf.string?.contains("Searchable invoice 12345") == true)
        XCTAssertFalse(pdf.findString("invoice", withOptions: .caseInsensitive).isEmpty)
    }

    func testRenamingAndDuplicatingPreserveBookmarkSidecar() throws {
        let url = try library.createWelcome()
        let workspace = PDFWorkspace(url: url)
        workspace.toggleBookmark()
        try library.duplicate(try XCTUnwrap(library.documents.first))
        XCTAssertEqual(library.documents.count, 2)
        let duplicate = try XCTUnwrap(library.documents.first { $0.url != url })
        XCTAssertEqual(PDFWorkspace(url: duplicate.url).bookmarks, [0])
        try library.rename(duplicate, to: "Renamed")
        let renamed = try XCTUnwrap(library.documents.first { $0.title == "Renamed" })
        XCTAssertEqual(PDFWorkspace(url: renamed.url).bookmarks, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.url.path))
    }

    func testEditingProtectedDocumentPreservesPasswordOnSave() throws {
        let source = PDFWorkspace(url: try library.createWelcome())
        let protectedURL = try XCTUnwrap(source.export(password: "original-password"))
        defer { try? FileManager.default.removeItem(at: protectedURL.deletingLastPathComponent()) }
        let workspace = PDFWorkspace(url: protectedURL)
        workspace.unlock("original-password")
        workspace.addText("Protected note", note: true)
        XCTAssertTrue(workspace.save())
        let reopened = try XCTUnwrap(PDFDocument(url: protectedURL))
        XCTAssertTrue(reopened.isLocked)
        XCTAssertTrue(reopened.unlock(withPassword: "original-password"))
        XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.contents == "Protected note" } == true)
    }

    func testFormTextValuePersistsAndCanBeUndone() throws {
        let url = try library.createWelcome()
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let widget = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 200, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Customer"
        pdf.page(at: 0)?.addAnnotation(widget)
        XCTAssertTrue(pdf.write(to: url))
        let workspace = PDFWorkspace(url: url)
        let field = try XCTUnwrap(workspace.page?.annotations.first { $0.fieldName == "Customer" })
        workspace.setFormValue(field, value: "Ada")
        XCTAssertEqual(field.widgetStringValue, "Ada")
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.fieldName == "Customer" }?.widgetStringValue, "Ada")
        workspace.undo()
        XCTAssertNotEqual(workspace.page?.annotations.first { $0.fieldName == "Customer" }?.widgetStringValue, "Ada")
    }

    func testMuPDFReplacementUpdatesPDFKitAndUndoRestoresOriginal() async throws {
        XCTAssertEqual(MuPDFEngine.version, "1.28.6")
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let selection = try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first)
        let page = try XCTUnwrap(selection.pages.first)
        try await workspace.replaceContent(operation: .replaceText, page: 0,
            region: selection.bounds(for: page), text: "Studio", fontSize: 6)
        XCTAssertTrue(workspace.document?.string?.contains("Studio") == true)
        XCTAssertFalse(workspace.document?.string?.contains("Paper Studio") == true)
        XCTAssertTrue(workspace.dirty)
        workspace.undo()
        XCTAssertTrue(workspace.document?.string?.contains("Paper Studio") == true)
    }

    func testMuPDFFailedReplacementLeavesDocumentAndHistoryIntact() async throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let original = workspace.document?.string
        do {
            try await workspace.replaceContent(operation: .replaceText, page: 0,
                region: CGRect(x: 0, y: 0, width: 20, height: 20), text: String(repeating: "X", count: 1000), fontSize: 12)
            XCTFail("Oversized replacement must fail")
        } catch {
            XCTAssertEqual(workspace.document?.string, original)
            XCTAssertFalse(workspace.canUndo)
            XCTAssertFalse(workspace.dirty)
        }
    }

    func testMuPDFWordExportProducesAnOfficeArchive() async throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let url = try await workspace.exportWord()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension, "docx")
        XCTAssertEqual(try Data(contentsOf: url).prefix(2), Data([0x50, 0x4b]))
        XCTAssertFalse(workspace.dirty)
    }

    func testToolCanBeEnabledWithoutSelectionAndToggledOff() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.toggleTool(.underline)
        XCTAssertEqual(workspace.activeTool, .underline)
        XCTAssertEqual(UIColor(workspace.inkColor), UIColor(Color.blue))
        XCTAssertFalse(workspace.dirty)
        XCTAssertNil(workspace.error)
        workspace.toggleTool(.underline)
        XCTAssertEqual(workspace.activeTool, .read)
        XCTAssertFalse(workspace.canUndo)
    }

    func testConfiguredToolColourSurvivesSwitchingTools() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.toggleTool(.underline)
        workspace.inkColor = .green
        workspace.toggleTool(.highlight)
        XCTAssertEqual(UIColor(workspace.inkColor), UIColor(Color.yellow))
        workspace.toggleTool(.underline)
        XCTAssertEqual(UIColor(workspace.inkColor), UIColor(Color.green))
    }

    func testUnderlineAppliesAutomaticallyWhenPDFSelectionChanges() async throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = DrawingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.workspace = workspace
        workspace.pdfView = view
        view.document = workspace.document
        workspace.toggleTool(.underline)
        view.configureTool()
        let applied = expectation(description: "Native PDF selection triggers underline")
        let observer = workspace.$revision.dropFirst().prefix(1).sink { _ in applied.fulfill() }
        defer { observer.cancel() }
        let selection = try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        await fulfillment(of: [applied], timeout: 4)
        XCTAssertTrue(workspace.page?.annotations.contains { $0.type == "Underline" } == true)
        XCTAssertEqual(workspace.activeTool, .underline)
        XCTAssertNil(view.currentSelection)
        workspace.undo()
        XCTAssertFalse(workspace.page?.annotations.contains { $0.type == "Underline" } == true)
    }

    func testMarkupDoesNotDuplicateAndReadModeDoesNotAnnotate() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let selection = try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first)
        workspace.commitToolSelection(selection)
        XCTAssertTrue(workspace.page?.annotations.isEmpty == true)
        workspace.toggleTool(.underline)
        workspace.commitToolSelection(selection)
        let count = workspace.page?.annotations.count
        workspace.commitToolSelection(selection)
        XCTAssertEqual(workspace.page?.annotations.count, count)
        workspace.undo()
        let revision = workspace.revision
        let foreign = try XCTUnwrap(PDFDocument(url: workspace.url)?.findString("Paper Studio", withOptions: []).first)
        workspace.commitToolSelection(foreign)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertTrue(workspace.page?.annotations.isEmpty == true)
    }

    func testCancelledSelectionGestureDoesNotCreateAnAnnotation() async throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = DrawingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.workspace = workspace
        workspace.pdfView = view
        view.document = workspace.document
        workspace.toggleTool(.underline)
        view.configureTool()
        let notApplied = expectation(description: "Cancelled selection must not annotate")
        notApplied.isInverted = true
        let observer = workspace.$revision.dropFirst().sink { _ in notApplied.fulfill() }
        defer { observer.cancel() }
        view.setCurrentSelection(try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first), animate: false)
        view.cancelToolGesture()
        await fulfillment(of: [notApplied], timeout: 1)
        XCTAssertNil(view.currentSelection)
        XCTAssertFalse(workspace.dirty)
    }

    func testTextPlacementUsesChosenBoundsAndPersistsFormatting() throws {
        let url = try library.createWelcome()
        let workspace = PDFWorkspace(url: url)
        let page = try XCTUnwrap(workspace.page)
        workspace.toggleTool(.text)
        workspace.textStyle.family = .serif
        workspace.textStyle.size = 24
        workspace.textStyle.weight = .bold
        workspace.textStyle.color = Color(UIColor.red)
        let bounds = CGRect(x: 45, y: 90, width: 290, height: 75)
        workspace.requestPlacement(on: page, bounds: bounds)
        let placement = try XCTUnwrap(workspace.placement)
        XCTAssertFalse(workspace.dirty)
        workspace.placeText("Placed here", at: placement)
        let annotation = try XCTUnwrap(workspace.selectedAnnotation)
        XCTAssertEqual(annotation.bounds, bounds)
        XCTAssertEqual(annotation.font?.pointSize, 24)
        XCTAssertTrue(annotation.font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        XCTAssertEqual(workspace.activeTool, .text)
        XCTAssertTrue(workspace.save())
        let restored = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.contents == "Placed here" })
        XCTAssertEqual(restored.bounds, bounds)
        XCTAssertEqual(try XCTUnwrap(restored.font?.pointSize), 24, accuracy: 0.1)
    }

    func testTextPlacementIsClippedToCropBoxAndRejectsTinyAreas() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let page = try XCTUnwrap(workspace.page)
        page.setBounds(CGRect(x: 20, y: 30, width: 400, height: 600), for: .cropBox)
        workspace.requestPlacement(on: page, bounds: CGRect(x: -20, y: -10, width: 100, height: 100))
        XCTAssertEqual(workspace.placement?.bounds, CGRect(x: 20, y: 30, width: 60, height: 60))
        workspace.placement = nil
        workspace.requestPlacement(on: page, bounds: CGRect(x: 50, y: 50, width: 2, height: 2))
        XCTAssertNil(workspace.placement)
        XCTAssertFalse(workspace.dirty)
    }

    func testTextFormattingAndBoxResizeCanBeUndone() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let page = try XCTUnwrap(workspace.page)
        workspace.requestPlacement(on: page, bounds: CGRect(x: 40, y: 80, width: 200, height: 80))
        workspace.placeText("Original", at: try XCTUnwrap(workspace.placement))
        let annotation = try XCTUnwrap(workspace.selectedAnnotation)
        workspace.textStyle.size = 30
        workspace.textStyle.weight = .bold
        workspace.updateTextAnnotation(annotation, text: "Edited")
        workspace.moveAnnotation(annotation, to: CGRect(x: 70, y: 100, width: 300, height: 100))
        XCTAssertEqual(annotation.bounds.width, 300)
        workspace.undo()
        XCTAssertEqual(workspace.page?.annotations.first?.bounds.width, 200)
        workspace.undo()
        XCTAssertEqual(workspace.page?.annotations.first?.contents, "Original")
        XCTAssertEqual(workspace.page?.annotations.first?.font?.pointSize, 12)
    }

    func testSignatureUsesChosenLocationInsteadOfPageCentre() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.activeTool = .signature; workspace.inkColor = .blue; workspace.lineWidth = 3
        workspace.addSignature([[CGPoint(x: 5, y: 5), CGPoint(x: 80, y: 20)]],
            size: CGSize(width: 100, height: 50), on: workspace.page, at: CGPoint(x: 45, y: 200))
        let annotation = try XCTUnwrap(workspace.page?.annotations.first)
        XCTAssertEqual(annotation.bounds.minX, 45)
        XCTAssertEqual(annotation.bounds.maxY, 200)
        XCTAssertEqual(annotation.color,UIColor(Color.blue))
        XCTAssertEqual(annotation.border?.lineWidth,3)
    }

    func testAllThreeLanguagesAreBundledAndTranslateInterfaceAndErrors() {
        XCTAssertEqual(L10n.tr("Souligner", language: .english), "Underline")
        XCTAssertEqual(L10n.tr("Souligner", language: .spanish), "Subrayar")
        XCTAssertEqual(L10n.tr("Souligner", language: .french), "Souligner")
        XCTAssertEqual(L10n.tr("Mot de passe incorrect.", language: .english), "Incorrect password.")
        XCTAssertEqual(L10n.tr("Zone de texte", language: .spanish), "Cuadro de texto")
    }

    func testInteractiveEditsAndUndoDoNotSerializeOrReplaceLargeDocument() throws {
        let url = try library.createWelcome()
        let document = try XCTUnwrap(SerializationTrackingDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        for _ in 0..<99 { document.insert(try XCTUnwrap(page.copy() as? PDFPage), at: document.pageCount) }
        let workspace = PDFWorkspace(url: url)
        workspace.document = document
        workspace.addText("Immediate", note: true)
        let annotation = try XCTUnwrap(page.annotations.first)
        workspace.moveAnnotation(annotation, to: annotation.bounds.offsetBy(dx: 10, dy: 10))
        workspace.removeAnnotation(annotation)
        for _ in 0..<3 { workspace.undo() }
        XCTAssertTrue(page.annotations.isEmpty)
        for _ in 0..<3 { workspace.redo() }
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.rotate()
        workspace.undo()
        XCTAssertEqual(page.rotation, 0)
        XCTAssertTrue(workspace.document === document)
        XCTAssertTrue(workspace.page === page)
        XCTAssertEqual(document.serializations, 0, "Interactive edits must not serialize a 100-page PDF")
    }

    func testUndoRedoAcrossNativeReplacementKeepsAnnotationHistoryValid() async throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let originalDocument = try XCTUnwrap(workspace.document)
        workspace.addText("Before replacement", note: true)
        let selection = try XCTUnwrap(originalDocument.findString("Paper Studio", withOptions: []).first)
        try await workspace.replaceContent(operation: .replaceText, page: 0,
            region: selection.bounds(for: try XCTUnwrap(selection.pages.first)), text: "Studio", fontSize: 6)
        let updatedDocument = try XCTUnwrap(workspace.document)
        workspace.addText("After replacement", note: true)
        workspace.undo()
        XCTAssertFalse(workspace.page?.annotations.contains { $0.contents == "After replacement" } == true)
        workspace.undo()
        XCTAssertTrue(workspace.document === originalDocument)
        workspace.undo()
        XCTAssertFalse(workspace.page?.annotations.contains { $0.contents == "Before replacement" } == true)
        workspace.redo()
        workspace.redo()
        XCTAssertTrue(workspace.document === updatedDocument)
        workspace.redo()
        XCTAssertTrue(workspace.page?.annotations.contains { $0.contents == "After replacement" } == true)
        XCTAssertTrue(workspace.page?.annotations.contains { $0.contents == "Before replacement" } == true)
    }

    func testOnlyEditedPageThumbnailChangesAndToolSwitchesDoNotInvalidateIt() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.merge([workspace.url])
        let first = try XCTUnwrap(workspace.page)
        let second = try XCTUnwrap(workspace.document?.page(at: 1))
        let initial = workspace.pageVersions
        workspace.toggleTool(.underline)
        workspace.toggleTool(.text)
        workspace.textStyle.size = 30
        XCTAssertEqual(workspace.pageVersions, initial)
        workspace.addText("Changed", note: true)
        XCTAssertEqual(workspace.pageVersions[ObjectIdentifier(first)], 1)
        XCTAssertNil(workspace.pageVersions[ObjectIdentifier(second)])
        workspace.undo()
        XCTAssertEqual(workspace.pageVersions[ObjectIdentifier(first)], 2)
        XCTAssertNil(workspace.pageVersions[ObjectIdentifier(second)])
    }

    func testThumbnailsRenderOffMainThreadAndReuseCachedImage() async throws {
        let page = ThreadTrackingPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        let renderer = PDFThumbnailRenderer()
        let size = CGSize(width: 110, height: 150)
        let rendered = await renderer.image(page: page, key: "page-v1", size: size)
        let cached = await renderer.image(page: page, key: "page-v1", size: size)
        let first = try XCTUnwrap(rendered), second = try XCTUnwrap(cached)
        XCTAssertFalse(page.renderedOnMainThread)
        XCTAssertEqual(page.renderCount, 1)
        XCTAssertTrue(first === second)
        _ = await renderer.image(page: page, key: "page-v2", size: size)
        XCTAssertEqual(page.renderCount, 2)
    }

    func testThumbnailCopyIsIndependentOfLiveAnnotations() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.addText("Live", note: true)
        let page = try XCTUnwrap(workspace.page)
        let annotation = try XCTUnwrap(page.annotations.first)
        let copy = try XCTUnwrap(page.copy() as? PDFPage)
        let copiedAnnotation = try XCTUnwrap(copy.annotations.first)
        XCTAssertFalse(copiedAnnotation === annotation)
        copiedAnnotation.contents = "Worker copy"
        XCTAssertEqual(annotation.contents, "Live")
    }

    private func canvas(_ workspace: PDFWorkspace) -> DrawingPDFView {
        let view = DrawingPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 1000))
        view.document = workspace.document
        view.workspace = workspace
        workspace.pdfView = view
        view.autoScales = true
        view.layoutDocumentView()
        view.layoutIfNeeded()
        view.configureTool()
        return view
    }

    func testDrawingPreviewUpdatesBeforeCommitAndIncludesFinalTouch() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.toggleTool(.pen)
        view.beginToolGesture(at: view.convert(CGPoint(x: 50, y: 100), from: page))
        view.updateToolGesture(at: view.convert(CGPoint(x: 100, y: 130), from: page))
        view.renderInteractionFrame()
        let preview = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "tool-preview" } as? CAShapeLayer)
        XCTAssertFalse(try XCTUnwrap(preview.path).isEmpty)
        XCTAssertTrue(preview.actions?["path"] is NSNull)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.canUndo)
        let final = CGPoint(x: 160, y: 170)
        view.endToolGesture(at: view.convert(final, from: page))
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertTrue(try XCTUnwrap(page.annotations.first).bounds.contains(final))
        XCTAssertNil(preview.path)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testLiveMoveUpdatesBoundsAndCancelledGestureRestoresThem() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.requestPlacement(on: page, bounds: CGRect(x: 50, y: 80, width: 200, height: 80))
        workspace.placeText("Move me", at: try XCTUnwrap(workspace.placement))
        let annotation = try XCTUnwrap(workspace.selectedAnnotation)
        let original = annotation.bounds, revision = workspace.revision
        workspace.toggleTool(.move)
        view.beginToolGesture(at: view.convert(CGPoint(x: original.midX, y: original.midY), from: page))
        view.updateToolGesture(at: view.convert(CGPoint(x: original.midX + 30, y: original.midY + 20), from: page))
        view.renderInteractionFrame()
        XCTAssertEqual(annotation.bounds.minX, original.minX + 30, accuracy: 0.01)
        XCTAssertEqual(workspace.revision, revision)
        view.cancelToolGesture()
        XCTAssertEqual(annotation.bounds, original)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty, "Cancelling must not add an undo entry")
    }

    func testTextBoxDragUsesFinalTouchAndDoesNotCreateContentUntilApplied() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.toggleTool(.text)
        view.beginToolGesture(at: view.convert(CGPoint(x: 50, y: 100), from: page))
        view.endToolGesture(at: view.convert(CGPoint(x: 250, y: 180), from: page))
        let input = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "inline-annotation-text" } as? UITextView)
        let bounds = view.convert(input.frame, to: page)
        XCTAssertEqual(bounds.minX, 50, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 200, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 80, accuracy: 0.01)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.dirty)
        XCTAssertNil(workspace.placement, "Text entry belongs on the page, without presenting a sheet")
        XCTAssertEqual(input.backgroundColor,.clear, "Typing must leave the underlying page visible")
        input.text = "Type directly here"
        workspace.textStyle.size = 24
        workspace.textStyle.weight = .bold
        XCTAssertEqual(try XCTUnwrap(input.font?.pointSize), 24 * view.scaleFactor, accuracy: 0.01)
        XCTAssertTrue(input.font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        view.finishTextEntry()
        XCTAssertEqual(page.annotations.first?.contents, "Type directly here")
        XCTAssertEqual(page.annotations.first?.font?.pointSize, 24)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testNativeSelectionAppliesOnNextFrameWithoutDebounce() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        workspace.toggleTool(.underline)
        view.setCurrentSelection(try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first), animate: false)
        view.renderInteractionFrame()
        XCTAssertTrue(workspace.page?.annotations.contains { $0.type == "Underline" } == true)
        XCTAssertNil(view.currentSelection)
    }

    func testTextResizeIsLiveAndCommitsOnlyOneUndoStep() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.requestPlacement(on: page, bounds: CGRect(x: 50, y: 300, width: 200, height: 80))
        workspace.placeText("Resize me", at: try XCTUnwrap(workspace.placement))
        let annotation = try XCTUnwrap(workspace.selectedAnnotation), original = annotation.bounds
        workspace.toggleTool(.move)
        workspace.selectedAnnotation = annotation
        let rect = view.convert(original, from: page)
        view.beginToolGesture(at: CGPoint(x: rect.maxX, y: rect.maxY))
        let final = CGPoint(x: rect.maxX + 60, y: rect.maxY + 30)
        view.updateToolGesture(at: final)
        view.renderInteractionFrame()
        XCTAssertGreaterThan(annotation.bounds.width, original.width)
        view.endToolGesture(at: final)
        workspace.undo()
        XCTAssertEqual(annotation.bounds, original)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testMarkupIsDrawnDuringDragWithoutAnIntermediateBlueSelection() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        let match = try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first)
        let bounds = match.bounds(for: page)
        for rotation in [0, 90] {
            page.rotation = rotation
            view.layoutDocumentView()
            for tool in [CanvasTool.underline, .highlight, .strikeOut] {
                workspace.toggleTool(tool)
                view.beginToolGesture(at: view.convert(CGPoint(x: bounds.minX + 1, y: bounds.midY), from: page))
                view.updateToolGesture(at: view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page))
                view.renderInteractionFrame()
                let preview = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "tool-preview" } as? CAShapeLayer)
                let first = try XCTUnwrap(preview.path).boundingBoxOfPath
                let firstLength = max(first.width, first.height)
                XCTAssertGreaterThan(firstLength, 0, "\(tool), rotation \(rotation)")
                XCTAssertNil(view.currentSelection)
                XCTAssertTrue(page.annotations.isEmpty)
                let final = view.convert(CGPoint(x: bounds.maxX - 1, y: bounds.midY), from: page)
                view.updateToolGesture(at: final)
                view.renderInteractionFrame()
                let last = try XCTUnwrap(preview.path).boundingBoxOfPath
                XCTAssertGreaterThan(max(last.width, last.height), firstLength)
                view.endToolGesture(at: final)
                let type = try XCTUnwrap(tool.markup).rawValue.replacingOccurrences(of: "/", with: "")
                XCTAssertTrue(page.annotations.contains { $0.type == type })
                workspace.undo()
                XCTAssertTrue(page.annotations.isEmpty)
            }
        }
    }

    func testExistingTextCanBeEditedInlineAndUndone() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        workspace.requestPlacement(on: try XCTUnwrap(workspace.page), bounds: CGRect(x: 50, y: 200, width: 250, height: 80))
        workspace.placeText("Original", at: try XCTUnwrap(workspace.placement))
        let annotation = try XCTUnwrap(workspace.selectedAnnotation)
        view.beginTextEntry(annotation: annotation)
        let input = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "inline-annotation-text" } as? UITextView)
        XCTAssertEqual(input.text, "Original")
        input.text = "Edited on the page"
        workspace.textStyle.size = 30
        view.finishTextEntry()
        XCTAssertEqual(annotation.contents, "Edited on the page")
        XCTAssertEqual(annotation.font?.pointSize, 30)
        workspace.undo()
        XCTAssertEqual(annotation.contents, "Original")
        XCTAssertEqual(annotation.font?.pointSize, 12)
    }

    func testCancellingInlineTextOrFinishingUnchangedTextDoesNotAddHistory() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        view.beginTextEntry(on: page, bounds: CGRect(x: 50, y: 200, width: 250, height: 80))
        let input = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "inline-annotation-text" } as? UITextView)
        input.text = "Cancelled"
        view.cancelTextEntry()
        XCTAssertFalse(workspace.dirty)
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.addText("Existing", note: true)
        view.beginTextEntry(annotation: try XCTUnwrap(page.annotations.first))
        view.finishTextEntry()
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty, "Opening unchanged text must not create an extra undo step")
    }

    func testLiveUnderlineIsVisibleAboveLateAddedPageContent() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        let view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        // PDFKit may insert its opaque page views after our overlay was created.
        let lateContent = UIView(frame: view.bounds)
        lateContent.backgroundColor = .white
        view.addSubview(lateContent)
        let match = try XCTUnwrap(workspace.document?.findString("Paper Studio", withOptions: []).first)
        let bounds = match.bounds(for: page)
        workspace.toggleTool(.underline)
        view.beginToolGesture(at: view.convert(CGPoint(x: bounds.minX + 1, y: bounds.midY), from: page))
        view.updateToolGesture(at: view.convert(CGPoint(x: bounds.maxX - 1, y: bounds.midY), from: page))
        view.renderInteractionFrame()
        let preview = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "tool-preview" } as? CAShapeLayer)
        let line = try XCTUnwrap(preview.path).boundingBoxOfPath
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: floor(line.midX), y: floor(line.midY), width: 1, height: 1)))
        var rgba: [UInt8] = [0, 0, 0, 0]
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(rgba[2]), Int(rgba[0]) + 50,
            "The blue underline must be visible during the drag: line=\(line), frame=\(preview.frame), color=\(String(describing: preview.strokeColor)), order=\(view.layer.sublayers?.map { String(describing: type(of: $0)) } ?? [])")
        XCTAssertTrue(page.annotations.isEmpty, "This must be the live preview, before committing an annotation")
        view.cancelToolGesture()
    }

    func testDocumentModesExposeWorkingToolGroupsAndFinishInlineText() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome())
        let view = canvas(workspace)
        XCTAssertTrue(EditorMode.annotate.tools.contains(.freeHighlighter))
        XCTAssertTrue(EditorMode.editPDF.tools.contains(.redact))
        XCTAssertTrue(EditorMode.fillSign.tools.contains(.signature))
        XCTAssertTrue(EditorMode.fillSign.tools.contains(.date))
        XCTAssertTrue(EditorMode.export.tools.isEmpty)
        workspace.activeTool = .text
        view.beginTextEntry(on:try XCTUnwrap(workspace.page),bounds:CGRect(x:50,y:200,width:200,height:60))
        let input = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "inline-annotation-text" } as? UITextView)
        input.text = "Switch modes"
        workspace.editorMode = .fillSign
        XCTAssertFalse(view.isEditingText)
        XCTAssertEqual(workspace.activeTool,.read)
        XCTAssertTrue(workspace.page?.annotations.contains { $0.contents == "Switch modes" } == true)
    }

    func testToolPresetsKeepMarkerSeparateAndShareShapeStyle() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome())
        workspace.activeTool = .freeHighlighter
        XCTAssertEqual(workspace.lineWidth,14)
        XCTAssertEqual(workspace.opacity,0.4)
        workspace.inkColor = .green; workspace.lineWidth = 20
        workspace.activeTool = .pen
        XCTAssertEqual(workspace.lineWidth,1.5)
        XCTAssertEqual(workspace.opacity,1)
        workspace.activeTool = .freeHighlighter
        XCTAssertEqual(workspace.lineWidth,20)
        XCTAssertEqual(UIColor(workspace.inkColor),UIColor(Color.green))
        workspace.activeTool = .rectangle
        workspace.inkColor = .red; workspace.lineWidth = 3; workspace.opacity = 0.75
        workspace.activeTool = .arrow
        XCTAssertEqual(workspace.lineWidth,3)
        XCTAssertEqual(workspace.opacity,0.75)
        XCTAssertEqual(UIColor(workspace.inkColor),UIColor(Color.red))
    }

    func testLineAndArrowPersistAsEditablePDFAnnotations() throws {
        let url = try library.createWelcome(), workspace = PDFWorkspace(url:url)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .arrow
        workspace.shapeStyle.doubleArrow = true
        workspace.shapeStyle.pattern = .dashed
        workspace.lineWidth = 3
        let a = CGPoint(x:50,y:200), b = CGPoint(x:200,y:270)
        workspace.addShape(on:page,from:a,to:b,tool:.arrow)
        let arrow = try XCTUnwrap(workspace.selectedAnnotation)
        XCTAssertEqual(arrow.type,"Line")
        XCTAssertEqual(arrow.startPoint,CGPoint(x:a.x-arrow.bounds.minX,y:a.y-arrow.bounds.minY))
        XCTAssertEqual(arrow.endPoint,CGPoint(x:b.x-arrow.bounds.minX,y:b.y-arrow.bounds.minY))
        XCTAssertEqual(arrow.startLineStyle,.closedArrow)
        XCTAssertEqual(arrow.endLineStyle,.closedArrow)
        XCTAssertEqual(arrow.border?.style,.dashed)
        XCTAssertTrue(workspace.save())
        let restored = try XCTUnwrap(PDFDocument(url:url)?.page(at:0)?.annotations.first)
        XCTAssertEqual(restored.endLineStyle,.closedArrow)
        XCTAssertEqual(restored.border?.lineWidth,3)
        XCTAssertEqual(restored.border?.dashPattern as? [NSNumber],[6,4])
    }

    func testSelectedArrowAppearanceChangesLiveAndUndoesAsOneEdit() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome())
        workspace.activeTool = .arrow
        workspace.addShape(on:try XCTUnwrap(workspace.page),from:CGPoint(x:50,y:100),to:CGPoint(x:200,y:200),tool:.arrow)
        let arrow = try XCTUnwrap(workspace.selectedAnnotation)
        let original = arrow.color
        workspace.beginAppearanceEditing()
        workspace.inkColor = .black; workspace.lineWidth = 5
        workspace.shapeStyle.doubleArrow = true
        workspace.previewSelectedAppearance()
        XCTAssertEqual(arrow.color,UIColor(Color.black))
        XCTAssertEqual(arrow.border?.lineWidth,5)
        XCTAssertEqual(arrow.startLineStyle,.closedArrow)
        // Undo must also work while the live settings popover is still open.
        workspace.undo()
        XCTAssertEqual(arrow.color,original)
        XCTAssertEqual(arrow.border?.lineWidth,2)
        XCTAssertEqual(arrow.startLineStyle,.none)
        workspace.undo()
        XCTAssertTrue(workspace.page?.annotations.isEmpty == true)
    }

    private func pagePixel(_ page: PDFPage, at point: CGPoint) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data:buffer.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:1,height:1))
            context.translateBy(x:0.5-point.x,y:0.5-point.y)
            page.draw(with:.mediaBox,to:context)
        }
        return bytes
    }

    func testSavedShapeAppearanceCanBeRecoloredAndUndoneVisibly() throws {
        let url = try library.createWelcome(), source = PDFWorkspace(url:url)
        source.activeTool = .line; source.lineWidth = 8
        source.addShape(on:try XCTUnwrap(source.page),from:CGPoint(x:350,y:100),to:CGPoint(x:550,y:100),tool:.line)
        XCTAssertTrue(source.save())
        let workspace = PDFWorkspace(url:url), page = try XCTUnwrap(workspace.page)
        let annotation = try XCTUnwrap(page.annotations.first), point = CGPoint(x:450,y:100)
        XCTAssertTrue(annotation.hasAppearanceStream, "Exercise an existing saved PDF appearance")
        XCTAssertGreaterThan(try pagePixel(page,at:point)[0],180)
        workspace.selectAnnotation(annotation)
        workspace.beginAppearanceEditing(); workspace.inkColor = Color(uiColor:.blue)
        workspace.previewSelectedAppearance()
        let live = try pagePixel(page,at:point)
        XCTAssertLessThan(live[0],70); XCTAssertGreaterThan(live[2],200)
        workspace.finishAppearanceEditing()
        XCTAssertTrue(workspace.save())
        let saved = try pagePixel(XCTUnwrap(PDFDocument(url:url)?.page(at:0)),at:point)
        XCTAssertLessThan(saved[0],70); XCTAssertGreaterThan(saved[2],200)
        workspace.undo()
        let restored = try pagePixel(page,at:point)
        XCTAssertGreaterThan(restored[0],180); XCTAssertLessThan(restored[2],130)
    }

    func testPartialEraserRegeneratesSavedInkAppearanceAndUndoRestoresIt() throws {
        let url = try library.createWelcome(), source = PDFWorkspace(url:url)
        source.activeTool = .pen; source.lineWidth = 8
        source.addInk(on:try XCTUnwrap(source.page),points:[CGPoint(x:350,y:100),CGPoint(x:550,y:100)],pressures:[nil,nil],marker:false)
        XCTAssertTrue(source.save())
        let workspace = PDFWorkspace(url:url), view = canvas(workspace), page = try XCTUnwrap(workspace.page)
        let original = try XCTUnwrap(page.annotations.first), center = CGPoint(x:450,y:100)
        XCTAssertTrue(original.hasAppearanceStream)
        XCTAssertLessThan(try pagePixel(page,at:center)[0],70)
        workspace.activeTool = .erase; workspace.eraserMode = .partial; workspace.eraserSize = 10
        view.beginToolGesture(at:view.convert(CGPoint(x:450,y:80),from:page))
        let end = view.convert(CGPoint(x:450,y:120),from:page)
        view.updateToolGesture(at:end); view.renderInteractionFrame()
        XCTAssertGreaterThan(try pagePixel(page,at:center)[0],230)
        XCTAssertLessThan(try pagePixel(page,at:CGPoint(x:390,y:100))[0],70)
        view.endToolGesture(at:end)
        XCTAssertTrue(workspace.save())
        let reopened = try XCTUnwrap(PDFDocument(url:url)?.page(at:0))
        XCTAssertGreaterThan(try pagePixel(reopened,at:center)[0],230)
        XCTAssertLessThan(try pagePixel(reopened,at:CGPoint(x:390,y:100))[0],70)
        workspace.undo()
        XCTAssertTrue(page.annotations.first === original)
        XCTAssertLessThan(try pagePixel(page,at:center)[0],70)
    }

    func testFreehandMarkerIsTranslucentAndVisibleDuringDrawing() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome()), view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .freeHighlighter
        view.beginToolGesture(at:view.convert(CGPoint(x:50,y:200),from:page))
        view.updateToolGesture(at:view.convert(CGPoint(x:100,y:225),from:page))
        view.updateToolGesture(at:view.convert(CGPoint(x:150,y:250),from:page))
        view.renderInteractionFrame()
        let preview = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "tool-preview" } as? CAShapeLayer)
        XCTAssertEqual(try XCTUnwrap(preview.strokeColor?.alpha),0.4,accuracy:0.01)
        XCTAssertEqual(preview.lineWidth,14*view.scaleFactor,accuracy:0.01)
        XCTAssertTrue(page.annotations.isEmpty)
        view.endToolGesture(at:view.convert(CGPoint(x:150,y:250),from:page))
        let ink = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(ink.type,"Ink")
        XCTAssertEqual(ink.paths?.count,1,"A continuous marker stroke must not accumulate opacity at sample joins")
        XCTAssertEqual(ink.color.cgColor.alpha,0.4,accuracy:0.01)
        XCTAssertEqual(ink.border?.lineWidth,14)
        XCTAssertTrue(workspace.save())
        let persisted = try XCTUnwrap(PDFDocument(url:workspace.url)?.page(at:0)?.annotations.first)
        XCTAssertEqual(persisted.color.cgColor.alpha,0.4,accuracy:0.01)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testPencilPressureProducesSavedVariableWidthsAndOneMovableStroke() throws {
        let url = try library.createWelcome(), workspace = PDFWorkspace(url:url)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .pen
        workspace.pressureSensitive = true
        workspace.addInk(on:page,points:[CGPoint(x:50,y:200),CGPoint(x:100,y:210),CGPoint(x:150,y:200)],pressures:[0.1,0.2,0.9],marker:false)
        XCTAssertGreaterThan(page.annotations.count,1)
        let widths = page.annotations.compactMap { $0.border?.lineWidth }
        XCTAssertLessThan(try XCTUnwrap(widths.min()),try XCTUnwrap(widths.max()))
        let first = try XCTUnwrap(page.annotations.first), original = first.bounds
        workspace.moveAnnotation(first,to:original.offsetBy(dx:20,dy:30))
        XCTAssertTrue(page.annotations.allSatisfy { $0.bounds == original.offsetBy(dx:20,dy:30) })
        workspace.undo()
        XCTAssertTrue(page.annotations.allSatisfy { $0.bounds == original })
        XCTAssertTrue(workspace.save())
        let reopened = try XCTUnwrap(PDFDocument(url:url)?.page(at:0))
        XCTAssertGreaterThan(Set(reopened.annotations.compactMap { $0.border?.lineWidth }).count,1)
        workspace.removeAnnotation(first)
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.undo()
        XCTAssertGreaterThan(page.annotations.count,1)
    }

    func testPressurePreviewHasDifferentWidthsBeforeCommit() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome()), view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .pen
        view.beginToolGesture(at:view.convert(CGPoint(x:50,y:200),from:page))
        view.updateToolGesture(at:view.convert(CGPoint(x:100,y:210),from:page),pressure:0.2)
        view.updateToolGesture(at:view.convert(CGPoint(x:150,y:200),from:page),pressure:0.9)
        view.renderInteractionFrame()
        let preview = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "pressure-preview" })
        let widths = (preview.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.lineWidth }
        XCTAssertGreaterThan(Set(widths).count,1)
        XCTAssertTrue(page.annotations.isEmpty)
        view.cancelToolGesture()
        XCTAssertFalse(workspace.dirty)
    }

    func testPartialEraserCutsOutTheInkInsteadOfPaintingOverIt() throws {
        let fragments = AnnotationGeometry.erased([CGPoint(x:0,y:0),CGPoint(x:100,y:0)],from:CGPoint(x:50,y:-10),to:CGPoint(x:50,y:10),radius:5)
        XCTAssertEqual(fragments.count,2)
        XCTAssertEqual(try XCTUnwrap(fragments.first?.last?.x),45,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(fragments.last?.first?.x),55,accuracy:0.01)
        XCTAssertEqual(fragments.first?.first,CGPoint(x:0,y:0))
        XCTAssertEqual(fragments.last?.last,CGPoint(x:100,y:0))
    }

    func testPartialErasingIsLivePersistsAndUndoesAsOneGesture() throws {
        let url = try library.createWelcome(), workspace = PDFWorkspace(url:url), view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .pen
        workspace.addInk(on:page,points:[CGPoint(x:50,y:200),CGPoint(x:250,y:200)],pressures:[nil,nil],marker:false)
        let original = try XCTUnwrap(page.annotations.first)
        workspace.activeTool = .erase; workspace.eraserMode = .partial; workspace.eraserSize = 5
        view.beginToolGesture(at:view.convert(CGPoint(x:150,y:180),from:page))
        view.updateToolGesture(at:view.convert(CGPoint(x:150,y:220),from:page))
        view.renderInteractionFrame()
        XCTAssertEqual(page.annotations.first?.paths?.count,2)
        XCTAssertFalse(page.annotations.first === original)
        view.endToolGesture(at:view.convert(CGPoint(x:150,y:220),from:page))
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(PDFDocument(url:url)?.page(at:0)?.annotations.first?.paths?.count,2)
        workspace.undo()
        XCTAssertTrue(page.annotations.first === original)
        XCTAssertEqual(original.paths?.count,1)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testCancelledEraserRestoresInkAndWholeEraserRemovesPressureGroup() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome()), view = canvas(workspace)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .pen
        workspace.addInk(on:page,points:[CGPoint(x:50,y:200),CGPoint(x:100,y:200),CGPoint(x:150,y:200)],pressures:[0.1,0.2,0.9],marker:false)
        let before = page.annotations
        workspace.activeTool = .erase; workspace.eraserMode = .whole
        let target = view.convert(CGPoint(x:75,y:200),from:page)
        view.beginToolGesture(at:target); view.updateToolGesture(at:CGPoint(x:target.x+1,y:target.y)); view.renderInteractionFrame()
        XCTAssertTrue(page.annotations.isEmpty)
        view.cancelToolGesture()
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init),before.map(ObjectIdentifier.init))
        view.activateTool(at:target)
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.undo()
        XCTAssertEqual(page.annotations.count,before.count)
    }

    func testCheckCrossDateAndStampCanBePlacedRepeatedlyAndReopened() throws {
        let url = try library.createWelcome(), workspace = PDFWorkspace(url:url)
        let page = try XCTUnwrap(workspace.page)
        workspace.activeTool = .checkmark
        workspace.inkColor = .blue; workspace.lineWidth = 4; workspace.opacity = 0.7
        workspace.placeMark(.checkmark,on:page,at:CGPoint(x:50,y:300))
        workspace.placeMark(.checkmark,on:page,at:CGPoint(x:90,y:300))
        workspace.placeMark(.cross,on:page,at:CGPoint(x:130,y:300))
        workspace.placeMark(.date,on:page,at:CGPoint(x:50,y:250))
        workspace.stampText = "REVIEWED"
        workspace.placeMark(.stamp,on:page,at:CGPoint(x:50,y:200))
        XCTAssertEqual(page.annotations.count,5)
        XCTAssertEqual(page.annotations.filter { $0.type == "Ink" }.count,3)
        XCTAssertEqual(page.annotations[2].paths?.count,2)
        XCTAssertEqual(page.annotations[0].border?.lineWidth,4)
        XCTAssertEqual(page.annotations[0].color.cgColor.alpha,0.7,accuracy:0.01)
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(PDFDocument(url:url)?.page(at:0)?.annotations.count,5)
        XCTAssertTrue(PDFDocument(url:url)?.page(at:0)?.annotations.contains { $0.contents == "REVIEWED" } == true)
    }

    func testPencilScribbleCanFocusATextAreaWithoutAnInitialTap() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome()), view = canvas(workspace)
        workspace.activeTool = .text
        let page = try XCTUnwrap(workspace.page)
        let input = try XCTUnwrap(view.focusScribble(at:view.convert(CGPoint(x:50,y:300),from:page)))
        input.text = "Hello"
        XCTAssertTrue(view.acceptsScribble)
        view.finishTextEntry()
        XCTAssertEqual(page.annotations.first?.contents,"Hello")
        workspace.activeTool = .pen
        workspace.convertHandwriting = true
        XCTAssertNotNil(view.focusScribble(at:view.convert(CGPoint(x:50,y:250),from:page)))
        view.cancelTextEntry()
        workspace.convertHandwriting = false
        XCTAssertFalse(view.acceptsScribble)
    }

    func testReadingLayoutAndMarginChangesDoNotModifyThePDF() throws {
        let workspace = PDFWorkspace(url:try library.createWelcome()), view = canvas(workspace)
        let crop = workspace.page?.bounds(for:.cropBox)
        var settings = ReadingSettings(); settings.layout = .horizontal
        view.configureReading(settings)
        XCTAssertEqual(view.displayDirection,.horizontal)
        settings.layout = .twoPages; view.configureReading(settings)
        XCTAssertEqual(view.displayMode,.twoUpContinuous)
        settings.layout = .vertical; settings.hideMargins = true; view.configureReading(settings)
        settings.hideMargins = false; view.configureReading(settings)
        XCTAssertTrue(view.autoScales)
        XCTAssertEqual(workspace.page?.bounds(for:.cropBox),crop)
        XCTAssertFalse(workspace.dirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testLinksPersistWithTheirAddressAndCanBeUndone() throws {
        let url = try library.createWelcome(), workspace = PDFWorkspace(url:url)
        let target = try XCTUnwrap(URL(string:"https://example.com/reference#page"))
        workspace.addLink(on:try XCTUnwrap(workspace.page),bounds:CGRect(x:50,y:250,width:120,height:30),url:target)
        XCTAssertTrue(workspace.save())
        XCTAssertEqual(PDFDocument(url:url)?.page(at:0)?.annotations.first?.url,target)
        workspace.undo()
        XCTAssertTrue(workspace.page?.annotations.isEmpty == true)
    }

    func testInsertedImageIsAnEditableStampAndRedactionCanBeUndone() async throws {
        let workspace = PDFWorkspace(url:try library.createWelcome())
        let png = UIGraphicsImageRenderer(size:CGSize(width:20,height:20)).image { context in UIColor.blue.setFill();context.cgContext.fill(CGRect(x:0,y:0,width:20,height:20)) }.pngData()
        try await workspace.replaceContent(operation:.insertImage,page:0,region:CGRect(x:50,y:300,width:80,height:80),image:try XCTUnwrap(png))
        XCTAssertTrue(workspace.page?.annotations.contains { $0.type == "Stamp" } == true)
        workspace.undo()
        XCTAssertTrue(workspace.page?.annotations.isEmpty == true)
        let selection = try XCTUnwrap(workspace.document?.findString("Paper Studio",withOptions:[]).first)
        let page = try XCTUnwrap(workspace.page)
        try await workspace.replaceContent(operation:.redact,page:0,region:selection.bounds(for:page))
        XCTAssertFalse(workspace.document?.string?.contains("Paper Studio") == true)
        workspace.undo()
        XCTAssertTrue(workspace.document?.string?.contains("Paper Studio") == true)
    }
}
