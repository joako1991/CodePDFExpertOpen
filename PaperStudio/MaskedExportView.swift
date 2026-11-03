import SwiftUI
import PDFKit

/// A separate export keeps the working document and its undo history out of the masked copy.
struct MaskedExportView: View {
    let document: PDFDocument
    let initialPage: Int
    let onExport: (URL) -> Void
    @State private var index = 0
    @State private var masks: [Int: [MaskedRegion]] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var exporting = false
    @State private var error: String?
    @State private var confirm = false
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tracez les zones à masquer. La copie sera entièrement transformée en images : texte sélectionnable, liens, formulaires et annotations éditables seront supprimés. L’original reste inchangé.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Précédente") { index -= 1 }.disabled(index == 0)
                Spacer()
                Text("Page \(index + 1) / \(document.pageCount)")
                Spacer()
                Button("Suivante") { index += 1 }.disabled(index + 1 >= document.pageCount)
            }
            GeometryReader { geometry in
                if let thumbnail {
                    let scale = min(geometry.size.width / thumbnail.size.width, geometry.size.height / thumbnail.size.height)
                    let size = CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                    let origin = CGPoint(x: (geometry.size.width - size.width) / 2, y: (geometry.size.height - size.height) / 2)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: thumbnail).resizable().frame(width: size.width, height: size.height)
                        ForEach(masks[index] ?? []) { region in
                            Rectangle().fill(.black).frame(width: region.rect.width * size.width, height: region.rect.height * size.height)
                                .offset(x: region.rect.minX * size.width, y: region.rect.minY * size.height)
                        }
                        if let start, let current {
                            Rectangle().fill(.black.opacity(0.7))
                                .frame(width: abs(current.x - start.x), height: abs(current.y - start.y))
                                .offset(x: min(start.x, current.x), y: min(start.y, current.y))
                        }
                    }
                    .frame(width: size.width, height: size.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if start == nil { start = clamped(value.startLocation, size) }
                        current = clamped(value.location, size)
                    }.onEnded { _ in
                        defer { start = nil; current = nil }
                        guard let start, let current else { return }
                        let rect = CGRect(x: min(start.x, current.x) / size.width, y: min(start.y, current.y) / size.height,
                                          width: abs(current.x - start.x) / size.width, height: abs(current.y - start.y) / size.height)
                        if rect.width > 0.002 && rect.height > 0.002 { masks[index, default: []].append(MaskedRegion(rect: rect)) }
                    })
                    .offset(x: origin.x, y: origin.y)
                }
            }.background(Color(uiColor: .secondarySystemBackground))
            HStack {
                Button("Annuler la dernière zone") { if !(masks[index] ?? []).isEmpty { masks[index]?.removeLast() } }
                    .disabled((masks[index] ?? []).isEmpty || exporting)
                Spacer()
                if exporting { ProgressView() }
                Button("Exporter la copie masquée") { confirm = true }
                    .buttonStyle(.borderedProminent).disabled(masks.values.allSatisfy(\.isEmpty) || exporting)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding().navigationTitle("Masquer des informations")
        .onAppear { index = initialPage; loadThumbnail() }
        .onChange(of: index) { _ in start = nil; current = nil; loadThumbnail() }
        .confirmationDialog("Créer une copie aplatie avec les zones masquées ?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Créer la copie") {
                exporting = true
                Task { @MainActor in
                    // Allow the progress indicator to appear before the synchronous PDF renderer starts.
                    await Task.yield()
                    defer { exporting = false }
                    do {
                        let data = try PDFConversions.rasterized(document, quality: .detailed, masks: masks)
                        let url = try PDFConversions.temporaryFile(data: data, name: "Copie masquée.pdf")
                        onExport(url)
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .interactiveDismissDisabled(exporting)
    }

    private func loadThumbnail() {
        thumbnail = document.page(at: index).map { PDFConversions.image(of: $0, quality: .balanced) }
    }

    private func clamped(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }
}
