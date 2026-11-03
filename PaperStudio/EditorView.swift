import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private struct SharedFile: Identifiable { let id = UUID(); let url: URL }
private enum EditorSheet: String, Identifiable {
    case placement, signature, password, ocr, editAnnotation, masked, optimize, forms, contentText, contentImage
    var id: String { rawValue }
}

struct EditorView: View {
    @StateObject private var workspace: PDFWorkspace
    let onClose: () -> Void
    @State private var showPages = true
    @State private var dimBackground = false
    @State private var search = ""
    @State private var sheet: EditorSheet?
    @State private var password = ""
    @State private var sharedFile: SharedFile?
    @State private var merging = false
    @State private var confirmDelete = false
    @State private var confirmClose = false
    @State private var pendingShare: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: String?
    @State private var nativeEditing = false
    @Environment(\.scenePhase) private var scenePhase

    init(url: URL, onClose: @escaping () -> Void) {
        _workspace = StateObject(wrappedValue: PDFWorkspace(url: url))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspace.document?.isLocked == true {
                VStack(spacing: 20) {
                    Image(systemName: "lock.doc").font(.system(size: 48)).foregroundStyle(.indigo)
                    Text("Document protégé").font(.title2.bold())
                    SecureField("Mot de passe du PDF", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Button("Déverrouiller") { workspace.unlock(password); password = "" }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.document != nil {
                tools
                Divider()
                HStack(spacing: 0) {
                    if showPages { pages.frame(width: 140); Divider() }
                    PDFCanvas(workspace: workspace, nightMode: dimBackground)
                }
                footer
            } else {
                Spacer()
                Text("Impossible d’ouvrir ce document.")
                Button("Retour à la bibliothèque", action: onClose)
                Spacer()
            }
        }
        .disabled(exportProgress != nil || nativeEditing)
        .overlay {
            if let exportProgress {
                VStack(spacing: 16) {
                    ProgressView(exportProgress)
                    Button("Annuler") { exportTask?.cancel() }
                }.padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let pendingShare { sharedFile = SharedFile(url: pendingShare); self.pendingShare = nil }
            workspace.placement = nil
            workspace.textTarget = nil
            if workspace.activeTool == .signature && workspace.signatureStrokes.isEmpty { workspace.activeTool = .read }
        }) { kind in sheetContent(kind) }
        .sheet(item: $sharedFile) { ActivitySheet(url: $0.url) }
        .fileImporter(isPresented: $merging, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            do { workspace.merge(try result.get()) } catch { workspace.error = error.localizedDescription }
        }
        .alert("Impossible de terminer", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(L10n.tr(workspace.error ?? "")) }
        .confirmationDialog("Supprimer la page \(workspace.pageIndex + 1) ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer la page", role: .destructive) { workspace.deletePage() }
        }
        .confirmationDialog("Enregistrer vos modifications avant de fermer ?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Enregistrer et fermer") { if workspace.save() { onClose() } }
            Button("Ignorer les modifications", role: .destructive, action: onClose)
            Button("Annuler", role: .cancel) {}
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background, workspace.dirty || workspace.hasFormFields { workspace.save() }
        }
        .onDisappear { exportTask?.cancel() }
        .onChange(of: workspace.placement?.id) { id in if id != nil { sheet = .placement } }
        .onChange(of: workspace.textTarget?.id) { id in if id != nil { sheet = .contentText } }
        .onChange(of: workspace.imageTarget?.id) { id in
            if id != nil { sheet = .contentImage }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                // Native checkbox/radio controls need not emit a text-change notification.
                if workspace.dirty || workspace.hasFormFields { confirmClose = true } else { onClose() }
            } label: { Label("Bibliothèque", systemImage: "chevron.left") }
            Spacer()
            Text(workspace.url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
            Spacer()
            Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!workspace.canUndo).accessibilityLabel("Annuler la dernière modification")
                .keyboardShortcut("z", modifiers: .command)
            Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!workspace.canRedo).accessibilityLabel("Rétablir la modification")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Enregistrer") { workspace.save() }
                .disabled(workspace.document == nil || workspace.document?.isLocked == true)
                .keyboardShortcut("s", modifiers: .command)
            Menu {
                Button("Partager une copie", systemImage: "square.and.arrow.up") { share(workspace.export()) }
                Button("Protéger une copie", systemImage: "lock") { password = ""; sheet = .password }
                Button("Extraire cette page", systemImage: "doc.on.doc") { share(workspace.export(currentPageOnly: true)) }
                Button("Page en image PNG", systemImage: "photo") { share(workspace.exportImage()) }
                Button("Exporter le texte", systemImage: "text.alignleft") { share(workspace.exportText()) }
                Button("Exporter vers Word (DOCX)", systemImage: "doc.text") { exportWord() }
                Button("Créer un PDF recherchable (OCR)", systemImage: "text.viewfinder") { exportSearchablePDF() }
                Button("Aplatir et réduire", systemImage: "arrow.down.right.and.arrow.up.left") { sheet = .optimize }
                Button("Masquer des informations", systemImage: "rectangle.fill") { sheet = .masked }
                Button("Imprimer", systemImage: "printer") {
                    guard let data = workspace.document?.dataRepresentation() else { return }
                    let controller = UIPrintInteractionController.shared
                    controller.printingItem = data
                    controller.present(animated: true)
                }
            } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
            .disabled(workspace.document == nil || workspace.document?.isLocked == true)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var tools: some View {
        EditorToolsView(workspace: workspace, showPages: $showPages,
            signature: { sheet = .signature },
            ocr: { sheet = .ocr; workspace.recognizeCurrentPage() },
            forms: { sheet = .forms }, merge: { merging = true },
            deletePage: { confirmDelete = true }, editAnnotation: { sheet = .editAnnotation })
    }

    private var pages: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(0..<(workspace.document?.pageCount ?? 0), id: \.self) { index in
                    Button { workspace.go(to: index) } label: {
                        VStack(spacing: 6) {
                            if let image = workspace.document?.page(at: index)?.thumbnail(of: CGSize(width: 110, height: 150), for: .mediaBox) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 100, height: 135)
                                    .background(.white)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(workspace.pageIndex == index ? Color.indigo : Color.clear, lineWidth: 3))
                            }
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Page \(index + 1)")
                }
            }.padding(.vertical, 20).id(workspace.revision)
        }.background(Color(uiColor: .secondarySystemBackground))
    }

    private var footer: some View {
        HStack {
            Button { workspace.go(to: workspace.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(workspace.pageIndex == 0).accessibilityLabel("Page précédente")
            Text("\(workspace.pageIndex + 1) / \(workspace.document?.pageCount ?? 0)").font(.caption.monospacedDigit())
            Button { workspace.toggleBookmark() } label: {
                Image(systemName: workspace.bookmarks.contains(workspace.pageIndex) ? "bookmark.fill" : "bookmark")
            }.accessibilityLabel("Ajouter ou retirer un signet")
            Menu {
                if workspace.bookmarks.isEmpty { Text("Aucun signet") }
                ForEach(workspace.bookmarks.sorted(), id: \.self) { index in
                    Button("Page \(index + 1)") { workspace.go(to: index) }
                }
            } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Liste des signets")
            Button { workspace.go(to: workspace.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(workspace.pageIndex + 1 >= (workspace.document?.pageCount ?? 0)).accessibilityLabel("Page suivante")
            Spacer()
            Text(L10n.tr(workspace.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            TextField("Rechercher du texte", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                .onSubmit { workspace.search(search) }
                .onChange(of: search) { if $0.isEmpty { workspace.search("") } }
            Menu {
                if workspace.searchResults.isEmpty { Text("Aucun résultat — validez avec Entrée") }
                ForEach(Array(workspace.searchResults.enumerated()), id: \.offset) { index, selection in
                    Button("\(index + 1). \(selection.string?.prefix(45) ?? "")") {
                        workspace.pdfView?.go(to: selection)
                        workspace.pdfView?.setCurrentSelection(selection, animate: true)
                    }
                }
            } label: { Text("\(workspace.searchResults.count) résultats").font(.caption) }
            Button { dimBackground.toggle() } label: { Image(systemName: dimBackground ? "sun.max" : "moon") }
                .accessibilityLabel("Assombrir le fond de lecture")
        }.padding(12).background(.bar)
    }

    @ViewBuilder
    private func sheetContent(_ kind: EditorSheet) -> some View {
        NavigationStack {
            Group {
                switch kind {
                case .placement:
                    if let placement = workspace.placement {
                        TextAnnotationEditor(workspace: workspace, placement: placement, annotation: nil, done: { sheet = nil })
                    }
                case .editAnnotation:
                    TextAnnotationEditor(workspace: workspace, placement: nil, annotation: workspace.selectedAnnotation, done: { sheet = nil })
                case .signature:
                    SignatureView { strokes, size in
                        workspace.signatureStrokes = strokes
                        workspace.signatureSize = size
                        workspace.activeTool = .signature
                        sheet = nil
                    }.navigationTitle("Votre signature")
                case .password:
                    Form {
                        Section("Protéger une copie PDF") {
                            SecureField("Nouveau mot de passe", text: $password)
                            Text("Conservez ce mot de passe : il sera nécessaire pour ouvrir la copie exportée.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Créer et partager la copie") {
                                pendingShare = workspace.export(password: password)
                                password = ""; sheet = nil
                            }.disabled(password.isEmpty)
                        }
                    }.navigationTitle("Protection")
                case .ocr:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Reconnaissance locale de la page \(workspace.pageIndex + 1). Vérifiez le résultat avant de l’utiliser.")
                            .foregroundStyle(.secondary)
                        if workspace.recognizing { ProgressView("Lecture du texte…") }
                        TextEditor(text: $workspace.recognizedText).font(.body)
                        Button("Copier le texte") { UIPasteboard.general.string = workspace.recognizedText }
                            .buttonStyle(.borderedProminent).disabled(workspace.recognizedText.isEmpty)
                    }.padding().navigationTitle("Texte reconnu")
                case .masked:
                    if let document = workspace.document {
                        MaskedExportView(document: document, initialPage: workspace.pageIndex) { url in pendingShare = url; sheet = nil }
                    }
                case .optimize:
                    if let document = workspace.document {
                        RasterExportView(document: document, originalSize: (try? Data(contentsOf: workspace.url).count) ?? 0) { url in pendingShare = url; sheet = nil }
                    }
                case .forms:
                    FormFieldsView(workspace: workspace)
                case .contentText:
                    if let target = workspace.textTarget {
                        ContentEditView(textTarget: target, imageTarget: nil, apply: { text, size, _ in
                            nativeEditing = true
                            defer { nativeEditing = false }
                            try await workspace.replaceContent(operation: .replaceText, page: target.page,
                                region: target.bounds, text: text, fontSize: size)
                        }, done: { sheet = nil })
                    }
                case .contentImage:
                    if let target = workspace.imageTarget {
                        ContentEditView(textTarget: nil, imageTarget: target, apply: { _, _, image in
                            nativeEditing = true
                            defer { nativeEditing = false }
                            try await workspace.replaceContent(operation: .replaceImage, page: target.page,
                                region: CGRect(origin: target.point, size: .zero), image: image)
                        }, done: { sheet = nil })
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { sheet = nil }.disabled(nativeEditing) } }
        }.presentationDetents([.large])
    }

    private func share(_ url: URL?) { if let url { sharedFile = SharedFile(url: url) } }

    private func exportSearchablePDF() {
        guard let document = workspace.document else { return }
        exportProgress = "Préparation de l’OCR…"
        exportTask = Task { @MainActor in
            defer { exportProgress = nil; exportTask = nil }
            do {
                let data = try await OCRService.searchablePDF(document) { page, count in
                    exportProgress = L10n.format("Reconnaissance : page %lld sur %lld", page, count)
                }
                try Task.checkCancellation()
                share(try PDFConversions.temporaryFile(data: data, name: L10n.tr("Document recherchable.pdf")))
            } catch is CancellationError {
                workspace.status = "Export OCR annulé"
            } catch { workspace.error = error.localizedDescription }
        }
    }

    private func exportWord() {
        exportProgress = "Conversion vers Word…"
        exportTask = Task { @MainActor in
            defer { exportProgress = nil; exportTask = nil }
            do { share(try await workspace.exportWord()) }
            catch is CancellationError { workspace.status = "Conversion Word annulée" }
            catch { workspace.error = error.localizedDescription }
        }
    }
}
