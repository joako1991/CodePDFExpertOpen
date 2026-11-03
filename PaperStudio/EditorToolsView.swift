// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct EditorToolsView: View {
    @ObservedObject var workspace: PDFWorkspace
    @Binding var showPages: Bool
    let signature: () -> Void
    let ocr: () -> Void
    let forms: () -> Void
    let merge: () -> Void
    let deletePage: () -> Void
    let editAnnotation: () -> Void
    @State private var settings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { showPages.toggle() } label: { Label("Pages", systemImage: "sidebar.left") }
                    ForEach(CanvasTool.allCases) { toolButton($0) }
                    Button { ocr() } label: { Label("OCR", systemImage: "text.viewfinder") }
                    Button { forms() } label: { Label("Formulaire", systemImage: "list.clipboard") }
                    organize
                }.padding(.horizontal, 16)
            }
            if workspace.activeTool != .read {
                HStack(spacing: 16) {
                    Text(LocalizedStringKey(workspace.activeTool.instruction)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { settings = true } label: { Label("Réglages de l’outil", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $settings) { configuration.padding().frame(width: 320).presentationCompactAdaptation(.popover) }
                    Button("Terminer") { workspace.activeTool = .read }.keyboardShortcut(.escape, modifiers: [])
                }.padding(.horizontal, 16)
            }
            if let annotation = workspace.selectedAnnotation {
                HStack {
                    Text("Annotation sélectionnée").font(.caption)
                    if annotation.type == "FreeText" || annotation.type == "Text" {
                        Button("Modifier le texte", action: editAnnotation)
                    }
                    Button("Supprimer l’annotation", role: .destructive) { workspace.removeAnnotation(annotation) }
                }.padding(.horizontal, 16)
            }
        }.buttonStyle(.bordered).padding(.vertical, 10).background(Color(uiColor: .secondarySystemBackground))
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        Button {
            workspace.toggleTool(tool)
            if tool == .signature, workspace.activeTool == .signature, workspace.signatureStrokes.isEmpty { signature() }
        } label: { Label(LocalizedStringKey(tool.title), systemImage: tool.symbol) }
            .tint(workspace.activeTool == tool ? .indigo : .secondary)
            .background(workspace.activeTool == tool ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityValue(Text(LocalizedStringKey(workspace.activeTool == tool ? "Activé" : "Désactivé")))
            .accessibilityIdentifier("tool-\(tool.rawValue)")
    }

    @ViewBuilder private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizedStringKey(workspace.activeTool.title)).font(.headline)
            if workspace.activeTool == .text { TextStyleControls(style: $workspace.textStyle) }
            else if workspace.activeTool == .signature { Button("Configurer la signature") { settings = false; signature() } }
            else if workspace.activeTool.markup != nil || [.pen, .rectangle, .oval].contains(workspace.activeTool) {
                ColorPicker("Couleur", selection: $workspace.inkColor, supportsOpacity: false)
                Stepper(value: $workspace.lineWidth, in: 1...8) { Text("Épaisseur : \(Int(workspace.lineWidth)) pt") }
            } else { Text(LocalizedStringKey(workspace.activeTool.instruction)) }
        }
    }

    private var organize: some View {
        Menu {
            Button("Tourner de 90°", systemImage: "rotate.right") { workspace.rotate() }
            Button("Déplacer avant", systemImage: "arrow.up") { workspace.movePage(by: -1) }.disabled(workspace.pageIndex == 0)
            Button("Déplacer après", systemImage: "arrow.down") { workspace.movePage(by: 1) }
                .disabled(workspace.pageIndex + 1 >= (workspace.document?.pageCount ?? 0))
            Button("Ajouter un autre PDF", systemImage: "plus.rectangle.on.rectangle", action: merge)
            Button("Supprimer la page", systemImage: "trash", role: .destructive, action: deletePage)
                .disabled((workspace.document?.pageCount ?? 0) < 2)
        } label: { Label("Organiser", systemImage: "square.stack.3d.up") }
    }
}

extension CanvasTool {
    var instruction: String {
        switch self {
        case .read: return "Faites défiler, zoomez ou sélectionnez du texte."
        case .highlight: return "Sélectionnez du texte pour le surligner."
        case .underline: return "Sélectionnez du texte pour le souligner."
        case .strikeOut: return "Sélectionnez du texte pour le barrer."
        case .text: return "Touchez la page pour écrire ou tracez la taille de la zone de texte."
        case .note: return "Touchez la page pour placer une note."
        case .signature: return "Touchez la page pour placer votre signature."
        case .pen: return "Dessinez sur la page avec le doigt ou le Pencil."
        case .rectangle, .oval: return "Tracez la forme directement sur la page."
        case .move: return "Déplacez une annotation. Tirez la poignée d’une zone de texte pour la redimensionner."
        case .erase: return "Touchez une annotation pour la supprimer."
        case .replaceText: return "Sélectionnez une ligne pour remplacer son contenu PDF."
        case .targetImage: return "Touchez l’image PDF à remplacer."
        }
    }
}
