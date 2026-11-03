// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI

struct ContentEditView: View {
    let textTarget: ContentTextTarget?
    let imageTarget: ContentImageTarget?
    let apply: (String, Float, Data) async throws -> Void
    let done: () -> Void
    @State private var text = ""
    @State private var fontSize: Double = 12
    @State private var photo: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var image: UIImage?
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Form {
            if let textTarget {
                Section("Texte existant") { Text(textTarget.text).foregroundStyle(.secondary) }
                Section("Nouvelle ligne") {
                    TextField("Texte de remplacement", text: $text)
                    Stepper("Taille : \(Int(fontSize)) pt", value: $fontSize, in: 4...72)
                    Text("Le texte sélectionné sera retiré du contenu PDF puis remplacé avec Helvetica ou une police de repli. La police et la mise en page d’origine ne sont pas conservées. Une ligne trop longue sera refusée.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if imageTarget != nil {
                Section("Image de remplacement") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choisir une image", systemImage: "photo") }
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200) }
                    if loading { ProgressView("Chargement…") }
                    Text("La dernière image PDF dessinée à l’endroit choisi sera remplacée dans son cadre actuel. Son ratio peut être modifié. Les images inline ne sont pas prises en charge.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Appliquer au contenu PDF") {
                    busy = true; error = nil
                    Task { @MainActor in
                        defer { busy = false }
                        do { try await apply(text, Float(fontSize), imageData ?? Data()); done() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || loading || (textTarget != nil ? text.isEmpty : imageData == nil))
                if busy { ProgressView("Traitement du PDF…") }
                if let error { Text(L10n.tr(error)).foregroundStyle(.red) }
                Text("L’opération peut être annulée depuis la barre d’outils du document après son application.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(LocalizedStringKey(textTarget == nil ? "Remplacer une image" : "Remplacer le texte"))
        .disabled(busy)
        .interactiveDismissDisabled(busy || loading)
        .onAppear {
            if let textTarget { text = textTarget.text; fontSize = min(18, max(4, Double(textTarget.bounds.height * 0.7))) }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            loading = true; imageData = nil; error = nil
            Task { @MainActor in
                defer { loading = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let source = UIImage(data: data) else { throw StudioError.invalidPDF }
                    let scale = min(1, 4096 / max(source.size.width, source.size.height))
                    let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
                    guard let png = normalized.pngData() else { throw StudioError.invalidPDF }
                    image = normalized; imageData = png
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
