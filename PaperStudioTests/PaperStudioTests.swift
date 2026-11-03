import XCTest
import PDFKit
import Combine
import SwiftUI
@testable import PaperStudio

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
        workspace.commitToolSelection(selection) // Selection belongs to the document replaced by undo.
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
        XCTAssertEqual(workspace.page?.annotations.first?.font?.pointSize, 16)
    }

    func testSignatureUsesChosenLocationInsteadOfPageCentre() throws {
        let workspace = PDFWorkspace(url: try library.createWelcome())
        workspace.addSignature([[CGPoint(x: 5, y: 5), CGPoint(x: 80, y: 20)]],
            size: CGSize(width: 100, height: 50), on: workspace.page, at: CGPoint(x: 45, y: 200))
        let annotation = try XCTUnwrap(workspace.page?.annotations.first)
        XCTAssertEqual(annotation.bounds.minX, 45)
        XCTAssertEqual(annotation.bounds.maxY, 200)
    }

    func testAllThreeLanguagesAreBundledAndTranslateInterfaceAndErrors() {
        XCTAssertEqual(L10n.tr("Souligner", language: .english), "Underline")
        XCTAssertEqual(L10n.tr("Souligner", language: .spanish), "Subrayar")
        XCTAssertEqual(L10n.tr("Souligner", language: .french), "Souligner")
        XCTAssertEqual(L10n.tr("Mot de passe incorrect.", language: .english), "Incorrect password.")
        XCTAssertEqual(L10n.tr("Zone de texte", language: .spanish), "Cuadro de texto")
    }
}
