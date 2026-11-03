import SwiftUI
import PDFKit

struct RasterExportView: View {
    let document: PDFDocument
    let originalSize: Int
    let onExport: (URL) -> Void
    @State private var quality: RasterQuality = .balanced
    @State private var exporting = false
    @State private var resultURL: URL?
    @State private var resultSize = 0
    @State private var error: String?

    var body: some View {
        Form {
            Section("Copie aplatie") {
                Text("Chaque page sera convertie en image. Les formulaires, liens et annotations ne seront plus interactifs ; le texte ne sera plus sélectionnable. L’original reste inchangé.")
                Picker("Qualité", selection: $quality) {
                    ForEach(RasterQuality.allCases) { item in Text(item.title).tag(item) }
                }.disabled(exporting)
                Text("La taille dépend du document. Un PDF déjà optimisé peut devenir plus volumineux.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Générer la copie") {
                    exporting = true; error = nil; resultURL = nil
                    Task { @MainActor in
                        await Task.yield()
                        defer { exporting = false }
                        do {
                            let data = try PDFConversions.rasterized(document, quality: quality)
                            resultSize = data.count
                            resultURL = try PDFConversions.temporaryFile(data: data, name: "Copie aplatie.pdf")
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(exporting)
                if exporting { ProgressView("Préparation des pages…") }
            }
            if let resultURL {
                Section("Résultat") {
                    LabeledContent("Original enregistré", value: ByteCountFormatter.string(fromByteCount: Int64(originalSize), countStyle: .file))
                    LabeledContent("Copie", value: ByteCountFormatter.string(fromByteCount: Int64(resultSize), countStyle: .file))
                    Button("Partager cette copie") { onExport(resultURL) }.buttonStyle(.borderedProminent)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Aplatir et réduire")
            .interactiveDismissDisabled(exporting)
    }
}
