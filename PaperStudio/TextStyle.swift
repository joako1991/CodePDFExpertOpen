// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

enum TextFamily: String, CaseIterable, Identifiable {
    case system, helvetica, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "Sans empattement"; case .helvetica: return "Helvetica"; case .serif: return "Avec empattement"; case .monospaced: return "Monospace" }
    }
}

enum TextWeight: String, CaseIterable, Identifiable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String {
        switch self { case .regular: return "Normal"; case .medium: return "Moyen"; case .semibold: return "Demi-gras"; case .bold: return "Gras" }
    }
    var uiWeight: UIFont.Weight {
        switch self { case .regular: return .regular; case .medium: return .medium; case .semibold: return .semibold; case .bold: return .bold }
    }
}

struct TextStyle: Equatable {
    var family: TextFamily = .helvetica
    var size: Double = 12
    var weight: TextWeight = .regular
    var color: Color = .black
    var availableWeights: [TextWeight] { family == .serif ? [.regular, .bold] : (family == .helvetica ? [.regular,.medium,.bold] : TextWeight.allCases) }
    var font: UIFont {
        switch family {
        case .system: return UIFont.systemFont(ofSize: CGFloat(size), weight: weight.uiWeight)
        case .monospaced: return UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight.uiWeight)
        case .helvetica:
            let name = weight == .regular ? "HelveticaNeue" : (weight == .medium ? "HelveticaNeue-Medium" : "HelveticaNeue-Bold")
            return UIFont(name:name,size:CGFloat(size)) ?? UIFont.systemFont(ofSize:CGFloat(size),weight:weight.uiWeight)
        case .serif:
            // Explicit installed faces preserve bold in both UIKit and PDFKit appearance streams.
            return UIFont(name: weight == .regular ? "Georgia" : "Georgia-Bold", size: CGFloat(size)) ??
                UIFont.systemFont(ofSize: CGFloat(size), weight: weight == .regular ? .regular : .bold)
        }
    }
    mutating func useFamily(_ family: TextFamily) {
        self.family = family
        if !availableWeights.contains(weight) { weight = weight == .medium ? .regular : .bold }
    }
}

struct AnnotationPlacement: Identifiable {
    let id = UUID()
    let page: PDFPage
    let bounds: CGRect
    let note: Bool
}

struct TextStyleControls: View {
    @Binding var style: TextStyle
    private var familySelection: Binding<TextFamily> {
        Binding(get: { style.family }, set: { family in
            var updated = style
            updated.useFamily(family)
            style = updated
        })
    }
    var body: some View {
        Picker("Police", selection: familySelection) {
            ForEach(TextFamily.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        Stepper(value: $style.size, in: 6...96) { Text("Taille : \(Int(style.size)) pt") }
        Picker("Graisse", selection: $style.weight) {
            ForEach(style.availableWeights) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        ColorPicker("Couleur du texte", selection: $style.color, supportsOpacity: false)
    }
}
