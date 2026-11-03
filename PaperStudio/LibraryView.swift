import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import PhotosUI
import VisionKit

struct LibraryView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @State private var selected: URL?
    @State private var query = ""
    @State private var importing = false
    @State private var pendingDelete: LibraryDocument?
    @State private var recentOnly = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var scanning = false
    @State private var importingImages = false
    @State private var renaming: LibraryDocument?
    @State private var newName = ""
    @State private var showLegal = false
    @AppStorage("appLanguage") private var language: AppLanguage = .preferred
    private var filtered: [LibraryDocument] {
        library.documents.filter {
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
            (!recentOnly || $0.modified > Date().addingTimeInterval(-7 * 86400))
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Paper Studio", systemImage: "doc.richtext")
                    .font(.title2.bold()).padding(.top, 20)
                Text("VOTRE ESPACE PDF").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button { recentOnly = false; selected = nil } label: {
                    Label("Tous les documents", systemImage: "square.grid.2x2")
                }.buttonStyle(.borderedProminent).disabled(selected != nil)
                Button { recentOnly = true; selected = nil } label: {
                    Label("Cette semaine", systemImage: "clock")
                }.disabled(selected != nil)
                Divider()
                Button { importing = true } label: { Label("Importer un PDF", systemImage: "plus.circle") }
                PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                    Label("Images vers PDF", systemImage: "photo.on.rectangle.angled")
                }.disabled(importingImages || selected != nil)
                Button { scanning = true } label: { Label("Scanner un document", systemImage: "doc.viewfinder") }
                    .disabled(!VNDocumentCameraViewController.isSupported || selected != nil)
                Button {
                    do { selected = try library.createWelcome() }
                    catch { library.error = error.localizedDescription }
                } label: { Label("Document de découverte", systemImage: "sparkles") }.disabled(selected != nil)
                if importingImages { ProgressView("Création du PDF…") }
                Spacer()
                Picker("Langue", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("app-language")
                Button { showLegal = true } label: { Label("À propos et licences", systemImage: "info.circle") }
                Label("Sur cet iPad", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Vos fichiers sont conservés localement. Exportez une copie pour les partager.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            if let selected {
                EditorView(url: selected) { self.selected = nil; try? library.reload() }
                    .id(selected)
            } else {
                libraryContent
            }
        }
        .sheet(isPresented: $showLegal) { LegalView() }
        .sheet(isPresented: $scanning) {
            DocumentScanner { result in
                scanning = false
                do {
                    let images = try result.get()
                    if !images.isEmpty { selected = try library.createFromImages(images, name: L10n.tr("Numérisation")) }
                } catch { library.error = error.localizedDescription }
            }
        }
        .onChange(of: photos) { items in
            guard !items.isEmpty else { return }
            importingImages = true
            Task { @MainActor in
                defer { importingImages = false; photos = [] }
                do {
                    var images: [UIImage] = []
                    for item in items {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw StudioError.invalidPDF }
                        images.append(image)
                    }
                    selected = try library.createFromImages(images)
                } catch { library.error = error.localizedDescription }
            }
        }
        .alert("Renommer le document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom du document", text: $newName)
            Button("Renommer") {
                if let item = renaming {
                    do { try library.rename(item, to: newName) } catch { library.error = error.localizedDescription }
                }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { _ = try library.importPDF(url) }
            } catch { library.error = error.localizedDescription }
        }
        .alert("Impossible de terminer", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(L10n.tr(library.error ?? "")) }
        .confirmationDialog("Supprimer ce document de la bibliothèque ?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let item = pendingDelete {
                    do { try library.delete(item) } catch { library.error = error.localizedDescription }
                }
                pendingDelete = nil
            }
        }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(recentOnly ? "Cette semaine" : "Mes documents")).font(.largeTitle.bold())
                        Text("Un peu de clarté dans toutes vos idées.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { importing = true } label: { Label("Importer", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                HStack(spacing: 20) {
                    Image(systemName: "pencil.and.outline").font(.largeTitle)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("De la lecture à l’action").font(.title3.bold())
                        Text("Annotez, signez et assemblez vos documents dans un seul espace.")
                    }
                    Spacer()
                }.padding(28).foregroundStyle(.white)
                    .background(LinearGradient(colors: [.indigo, Color(red: 0.37, green: 0.30, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                TextField("Rechercher dans la bibliothèque", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Rechercher un document")
                HStack {
                    Text("\(filtered.count) documents").font(.headline)
                    Spacer()
                    Text("Dernière modification").font(.caption).foregroundStyle(.secondary)
                }
                if filtered.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 48)).foregroundStyle(.indigo)
                        Text(LocalizedStringKey(query.isEmpty ? "Votre bibliothèque vous attend" : "Aucun document trouvé")).font(.title2.bold())
                        Text("Importez un PDF depuis Fichiers, ou créez un document de découverte.").foregroundStyle(.secondary)
                        Button("Créer un document de découverte") {
                            do { selected = try library.createWelcome() } catch { library.error = error.localizedDescription }
                        }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity).padding(40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 24)], spacing: 24) {
                    ForEach(filtered) { item in
                        Button { selected = item.url } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                PDFCover(url: item.url).frame(height: 210).frame(maxWidth: .infinity)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 10)).clipped()
                                Text(item.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: item.url) { Label("Partager", systemImage: "square.and.arrow.up") }
                                Button("Renommer", systemImage: "pencil") { newName = item.title; renaming = item }
                                Button("Dupliquer", systemImage: "doc.on.doc") {
                                    do { try library.duplicate(item) } catch { library.error = error.localizedDescription }
                                }
                                Button("Supprimer", role: .destructive) { pendingDelete = item }
                            }
                    }
                }
            }.padding(36)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
}

struct PDFCover: View {
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
            else { Image(systemName: "doc.richtext").font(.system(size: 50)).foregroundStyle(.indigo) }
        }.task(id: url) {
            thumbnail = PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 320, height: 420), for: .mediaBox)
        }
    }
}
