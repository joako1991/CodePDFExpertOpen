// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

enum EditorMode: String, CaseIterable, Identifiable {
    case annotate, editPDF, fillSign, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .annotate: return "Annoter"
        case .editPDF: return "Modifier le PDF"
        case .fillSign: return "Remplir et signer"
        case .export: return "Exporter"
        }
    }
    var tools: [CanvasTool] {
        switch self {
        case .annotate: return [.read, .highlight, .underline, .strikeOut, .text, .pen, .freeHighlighter, .erase, .note, .rectangle, .oval, .line, .arrow, .move]
        case .editPDF: return [.read, .replaceText, .targetImage, .insertImage, .link, .redact]
        case .fillSign: return [.read, .text, .signature, .date, .checkmark, .cross, .stamp, .insertImage, .move]
        case .export: return []
        }
    }
}

enum StrokePattern: String, CaseIterable, Identifiable {
    case solid, dashed, dotted
    var id: String { rawValue }
    var title: String { switch self { case .solid: return "Continu"; case .dashed: return "Tirets"; case .dotted: return "Pointillés" } }
    var dash: [CGFloat] { switch self { case .solid: return []; case .dashed: return [6, 4]; case .dotted: return [1, 3] } }
}

struct AnnotationShapeStyle: Equatable {
    var pattern: StrokePattern = .solid
    var filled = false
    var doubleArrow = false
}

enum EraserMode: String, CaseIterable, Identifiable {
    case whole, partial
    var id: String { rawValue }
    var title: String { self == .whole ? "Trait entier" : "Partiel" }
}

enum ReadingLayout: String, CaseIterable, Identifiable {
    case vertical, horizontal, twoPages
    var id: String { rawValue }
    var title: String { switch self { case .vertical: return "Défilement vertical"; case .horizontal: return "Défilement horizontal"; case .twoPages: return "Deux pages" } }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case day, sepia, night
    var id: String { rawValue }
    var title: String { switch self { case .day: return "Jour"; case .sepia: return "Sépia"; case .night: return "Nuit" } }
}

struct ReadingSettings: Equatable {
    var layout: ReadingLayout = .vertical
    var theme: ReadingTheme = .day
    var brightness: Double = 0
    var hideMargins = false
    var keepAwake = false
}

enum DocumentPanel: String, CaseIterable, Identifiable {
    case pages, outline, annotations, bookmarks
    var id: String { rawValue }
    var title: String { switch self { case .pages: return "Pages"; case .outline: return "Sommaire"; case .annotations: return "Annotations"; case .bookmarks: return "Signets" } }
    var symbol: String { switch self { case .pages: return "square.grid.2x2"; case .outline: return "list.bullet.indent"; case .annotations: return "pencil.tip.crop.circle"; case .bookmarks: return "bookmark" } }
}

enum EditorExportAction: String, CaseIterable, Identifiable {
    case share, word, text, image, searchable, optimize, protect, printDocument
    var id: String { rawValue }
    var title: String {
        switch self {
        case .share: return "Partager une copie"
        case .word: return "Exporter vers Word (DOCX)"
        case .text: return "Exporter le texte"
        case .image: return "Page en image PNG"
        case .searchable: return "Créer un PDF recherchable (OCR)"
        case .optimize: return "Aplatir et réduire"
        case .protect: return "Protéger une copie"
        case .printDocument: return "Imprimer"
        }
    }
    var symbol: String {
        switch self {
        case .share: return "square.and.arrow.up"
        case .word: return "doc.text"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .searchable: return "text.viewfinder"
        case .optimize: return "arrow.down.right.and.arrow.up.left"
        case .protect: return "lock"
        case .printDocument: return "printer"
        }
    }
}

extension CanvasTool {
    var isShape: Bool { [.rectangle, .oval, .line, .arrow].contains(self) }
    var isInk: Bool { self == .pen || self == .freeHighlighter }
    var draws: Bool { isInk || isShape }
    var capturesDrag: Bool { draws || selectsText || [.move, .text, .erase, .link, .redact].contains(self) }
    var defaultWidth: CGFloat { self == .freeHighlighter ? 14 : (self == .pen ? 1.5 : 2) }
}

enum ToolPalette {
    static let colors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple]
    static let names = ["Noir","Rouge","Orange","Jaune","Vert","Bleu","Violet"]
}
