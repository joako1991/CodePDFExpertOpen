import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct LibraryDocument: Identifiable {
    var id: URL { url }
    let url: URL
    let modified: Date
    let size: Int
    var title: String { url.deletingPathExtension().lastPathComponent }
}

enum StudioError: LocalizedError {
    case invalidPDF, writeFailed, lastPage, emptySelection
    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "Ce fichier PDF est illisible ou verrouillé."
        case .writeFailed: return "Impossible d’enregistrer le PDF. Votre original est conservé."
        case .lastPage: return "Un document doit conserver au moins une page."
        case .emptySelection: return "Sélectionnez d’abord du texte dans le document."
        }
    }
}

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published var documents: [LibraryDocument] = []
    @Published var error: String?
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    func reload() throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        documents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values = try url.resourceValues(forKeys: keys)
                return LibraryDocument(url: url, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
            }.sorted { $0.modified > $1.modified }
    }

    func uniqueURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var url = directory.appendingPathComponent(safe).appendingPathExtension("pdf")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(safe) \(suffix)").appendingPathExtension("pdf")
            suffix += 1
        }
        return url
    }

    @discardableResult
    func importPDF(_ source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard PDFDocument(url: source) != nil else { throw StudioError.invalidPDF }
        let target = uniqueURL(source.deletingPathExtension().lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        try reload()
        return target
    }

    func delete(_ item: LibraryDocument) throws {
        try FileManager.default.removeItem(at: item.url)
        let bookmarks = item.url.appendingPathExtension("bookmarks.json")
        if FileManager.default.fileExists(atPath: bookmarks.path) { try FileManager.default.removeItem(at: bookmarks) }
        try reload()
    }

    @discardableResult
    func createFromImages(_ images: [UIImage], name: String? = nil) throws -> URL {
        let data = try PDFConversions.fromImages(images)
        let url = uniqueURL(name ?? L10n.tr("Images"))
        try data.write(to: url, options: .atomic)
        try reload()
        return url
    }

    func rename(_ item: LibraryDocument, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        let target = uniqueURL(trimmed)
        try FileManager.default.moveItem(at: item.url, to: target)
        let sidecar = item.url.appendingPathExtension("bookmarks.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.moveItem(at: sidecar, to: target.appendingPathExtension("bookmarks.json"))
        }
        try reload()
    }

    func duplicate(_ item: LibraryDocument) throws {
        let target = try importPDF(item.url)
        let sidecar = item.url.appendingPathExtension("bookmarks.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.copyItem(at: sidecar, to: target.appendingPathExtension("bookmarks.json"))
        }
    }

    @discardableResult
    func createWelcome() throws -> URL {
        let url = uniqueURL(L10n.tr("Bienvenue dans Paper Studio"))
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 595, height: 14))
            let title = L10n.tr("Votre prochain chapitre.")
            title.draw(in: CGRect(x: 50, y: 90, width: 495, height: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.systemIndigo])
            let body = L10n.tr("Bienvenue dans Paper Studio\n\nActivez un outil, puis utilisez-le directement sur la page.\n\nActivez Souligner et sélectionnez du texte. Activez Texte, puis touchez la page ou tracez une zone. Réglez la police, la taille et la graisse dans les réglages de l’outil.\n\nChoisissez Déplacer pour repositionner une annotation ou redimensionner une zone de texte par sa poignée. Terminer désactive l’outil.\n\nVos documents restent sur cet appareil.")
            body.draw(in: CGRect(x: 50, y: 220, width: 495, height: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 19), .foregroundColor: UIColor.darkGray])
        }
        try data.write(to: url, options: .atomic)
        try reload()
        return url
    }
}
