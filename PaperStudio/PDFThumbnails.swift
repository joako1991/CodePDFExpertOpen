// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

/// Serial rendering keeps PDF rasterization off the main actor and limits memory use.
actor PDFThumbnailRenderer {
    static let shared = PDFThumbnailRenderer()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 24 * 1024 * 1024 }

    func image(page: PDFPage, key: String, size: CGSize) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        return autoreleasepool {
            let image = page.thumbnail(of: size, for: .mediaBox)
            cache.setObject(image, forKey: key as NSString, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
    }

    func cover(url: URL, modified: Date, size: CGSize) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(url.absoluteString)-\(modified.timeIntervalSince1970)-\(size)"
        if let image = cache.object(forKey: key as NSString) { return image }
        // A worker-owned document never reads the PDFView's mutable document concurrently.
        return autoreleasepool {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            return withExtendedLifetime(document) { image(page: page, key: key, size: size) }
        }
    }
}

struct PDFPageThumbnail: View, Equatable {
    let page: PDFPage
    let version: Int
    let namespace: UUID
    @State private var thumbnail: UIImage?
    private var key: String { "\(namespace)-\(ObjectIdentifier(page))-\(version)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.page === rhs.page && lhs.version == rhs.version && lhs.namespace == rhs.namespace
    }

    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .task(id: key) {
            // Transfer an independent page copy; the worker never touches the live page.
            guard !Task.isCancelled, let copy = page.copy() as? PDFPage else { return }
            let image = await PDFThumbnailRenderer.shared.image(page: copy, key: key, size: CGSize(width: 110, height: 150))
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}
