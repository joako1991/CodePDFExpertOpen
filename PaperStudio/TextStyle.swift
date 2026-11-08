// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

enum TextFamily: String, CaseIterable, Identifiable {
    case system, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "Sans empattement"; case .serif: return "Avec empattement"; case .monospaced: return "Monospace" }
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
    var family: TextFamily = .system
    var size: Double = 16
    var weight: TextWeight = .regular
    var color: Color = .black
    var availableWeights: [TextWeight] { family == .serif ? [.regular, .bold] : TextWeight.allCases }
    var font: UIFont {
        switch family {
        case .system: return UIFont.systemFont(ofSize: CGFloat(size), weight: weight.uiWeight)
        case .monospaced: return UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: weight.uiWeight)
        case .serif:
            // Explicit installed faces preserve bold in both UIKit and PDFKit appearance streams.
            return UIFont(name: weight == .regular ? "Georgia" : "Georgia-Bold", size: CGFloat(size)) ??
                UIFont.systemFont(ofSize: CGFloat(size), weight: weight == .regular ? .regular : .bold)
        }
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
            updated.family = family
            if !updated.availableWeights.contains(updated.weight) {
                updated.weight = updated.weight == .medium ? .regular : .bold
            }
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
