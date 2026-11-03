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

struct TextStyle {
    var family: TextFamily = .system
    var size: Double = 16
    var weight: TextWeight = .regular
    var color: Color = .black
    var font: UIFont {
        let system = UIFont.systemFont(ofSize: CGFloat(size), weight: weight.uiWeight)
        let design: UIFontDescriptor.SystemDesign = family == .serif ? .serif : (family == .monospaced ? .monospaced : .default)
        return UIFont(descriptor: system.fontDescriptor.withDesign(design) ?? system.fontDescriptor, size: CGFloat(size))
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
    var body: some View {
        Picker("Police", selection: $style.family) {
            ForEach(TextFamily.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        Stepper(value: $style.size, in: 6...96) { Text("Taille : \(Int(style.size)) pt") }
        Picker("Graisse", selection: $style.weight) {
            ForEach(TextWeight.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        ColorPicker("Couleur du texte", selection: $style.color, supportsOpacity: false)
    }
}

struct TextAnnotationEditor: View {
    @ObservedObject var workspace: PDFWorkspace
    let placement: AnnotationPlacement?
    let annotation: PDFAnnotation?
    let done: () -> Void
    @State private var text = ""
    private var isNote: Bool { placement?.note == true || annotation?.type == "Text" }
    var body: some View {
        Form {
            Section("Contenu") {
                TextEditor(text: $text).frame(minHeight: 140)
                    .font(Font(workspace.textStyle.font)).foregroundStyle(workspace.textStyle.color)
            }
            if !isNote {
                Section("Mise en forme") { TextStyleControls(style: $workspace.textStyle) }
            }
            Section {
                Button("Appliquer") {
                    if let annotation { workspace.updateTextAnnotation(annotation, text: text) }
                    else if let placement { workspace.placeText(text, at: placement) }
                    done()
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(LocalizedStringKey(isNote ? "Ajouter une note" : "Zone de texte"))
        .onAppear { text = annotation?.contents ?? ""; if let annotation { workspace.readTextStyle(from: annotation) } }
    }
}
