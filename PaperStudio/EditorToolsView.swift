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
    let pickImage: () -> Void
    let exportAction: (EditorExportAction) -> Void
    @State private var settings = false

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode du document", selection: $workspace.editorMode) {
                ForEach(EditorMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 600).padding(.horizontal)
                .accessibilityIdentifier("editor-mode")
            HStack(spacing: 8) {
                Button { showPages.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Panneau du document")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if workspace.editorMode == .export {
                            ForEach(EditorExportAction.allCases) { action in
                                Button { exportAction(action) } label: { Label(LocalizedStringKey(action.title),systemImage:action.symbol) }.buttonStyle(.bordered)
                            }
                        } else {
                            ForEach(workspace.editorMode.tools) { toolButton($0) }
                            if workspace.editorMode == .fillSign {
                                Button(action:forms) { Label("Formulaire",systemImage:"list.clipboard") }
                            }
                        }
                    }
                }
                if workspace.editorMode != .export {
                    Menu {
                        Button("OCR",systemImage:"text.viewfinder",action:ocr)
                        Button("Ajouter un autre PDF",systemImage:"plus.rectangle.on.rectangle",action:merge)
                        Button("Tourner de 90°",systemImage:"rotate.right") { workspace.rotate() }
                        Button("Déplacer avant",systemImage:"arrow.up") { workspace.movePage(by:-1) }.disabled(workspace.pageIndex == 0)
                        Button("Déplacer après",systemImage:"arrow.down") { workspace.movePage(by:1) }.disabled(workspace.pageIndex+1 >= (workspace.document?.pageCount ?? 0))
                        Button("Supprimer la page",systemImage:"trash",role:.destructive,action:deletePage).disabled((workspace.document?.pageCount ?? 0) < 2)
                    } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("Organiser")
                }
            }.padding(.horizontal,16)
            if workspace.activeTool != .read {
                HStack(spacing: 10) {
                    if editingText {
                        Menu {
                            ForEach(TextFamily.allCases) { family in
                                Button(LocalizedStringKey(family.title)) { setTextStyle { $0.useFamily(family) } }
                            }
                        } label: { Text(LocalizedStringKey(workspace.textStyle.family.title)).font(.caption) }
                        Button { setTextStyle { $0.size = max(6,$0.size-1) } } label: { Image(systemName:"minus") }
                        Text("\(Int(workspace.textStyle.size)) pt").font(.caption.monospacedDigit())
                        Button { setTextStyle { $0.size = min(96,$0.size+1) } } label: { Image(systemName:"plus") }
                    }
                    if showsAppearanceControls {
                        ForEach(Array(ToolPalette.colors.enumerated()),id:\.offset) { index,color in
                            Button {
                                workspace.beginAppearanceEditing()
                                if editingText { workspace.textStyle.color = color }
                                else { workspace.inkColor = color }
                                workspace.previewSelectedAppearance(); workspace.finishAppearanceEditing()
                            } label: {
                                Circle().fill(color).frame(width:19,height:19)
                                    .overlay(Circle().stroke(.primary.opacity(0.35),lineWidth:1))
                                    .padding(3).background(RoundedRectangle(cornerRadius:6).stroke(selectedColor == color ? Color.accentColor : .clear,lineWidth:2))
                            }.accessibilityLabel(Text(LocalizedStringKey(ToolPalette.names[index])))
                        }
                    }
                    Spacer(minLength:4)
                    Button { settings = true } label: { Image(systemName:"slider.horizontal.3") }
                        .accessibilityLabel("Réglages de l’outil")
                        .popover(isPresented:$settings) {
                            configuration.padding().frame(width:320)
                                .presentationCompactAdaptation(.popover)
                                .onAppear { workspace.beginAppearanceEditing() }
                                .onDisappear { workspace.finishAppearanceEditing() }
                                .onChange(of:workspace.inkColor) { _ in workspace.previewSelectedAppearance() }
                                .onChange(of:workspace.lineWidth) { _ in workspace.previewSelectedAppearance() }
                                .onChange(of:workspace.opacity) { _ in workspace.previewSelectedAppearance() }
                                .onChange(of:workspace.shapeStyle) { _ in workspace.previewSelectedAppearance() }
                                .onChange(of:workspace.textStyle) { _ in workspace.previewSelectedAppearance() }
                        }
                    Button("Terminer") { workspace.finishInteraction(); workspace.activeTool = .read }.font(.caption)
                }.padding(.horizontal,16)
                Text(LocalizedStringKey(workspace.activeTool.instruction)).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16)
            }
            if let annotation = workspace.selectedAnnotation {
                HStack {
                    Image(systemName:"cursorarrow").font(.caption)
                    Text(annotation.contents?.isEmpty == false ? annotation.contents! : L10n.tr("Annotation sélectionnée")).font(.caption).lineLimit(1)
                    Spacer()
                    if annotation.type == "FreeText" || annotation.type == "Text" { Button("Modifier le texte",action:editAnnotation) }
                    Button("Supprimer l’annotation",role:.destructive) { workspace.removeAnnotation(annotation) }
                }.font(.caption).padding(.horizontal,16)
            }
        }.buttonStyle(.plain).padding(.vertical,8).background(Color(uiColor:.secondarySystemBackground))
    }

    private var editingText: Bool { workspace.activeTool == .text || (workspace.activeTool == .move && workspace.selectedAnnotation?.type == "FreeText") }
    private var showsAppearanceControls: Bool {
        if workspace.activeTool == .move { return workspace.selectedAnnotation?.supportsAppearanceEditing == true }
        return ![.read, .erase, .insertImage, .targetImage, .link, .redact, .replaceText].contains(workspace.activeTool)
    }
    private var selectedColor: Color { editingText ? workspace.textStyle.color : workspace.inkColor }

    private func setTextStyle(_ change: (inout TextStyle) -> Void) {
        workspace.beginAppearanceEditing()
        var style = workspace.textStyle; change(&style); workspace.textStyle = style
        workspace.previewSelectedAppearance(); workspace.finishAppearanceEditing()
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        Button {
            if workspace.activeTool == tool && tool != .read { settings = true }
            else {
                workspace.finishInteraction(); workspace.activeTool = tool
                if tool == .signature && workspace.signatureStrokes.isEmpty { signature() }
                if tool == .insertImage { pickImage() }
            }
        } label: {
            Image(systemName:tool.symbol).font(.system(size:18)).frame(width:36,height:34)
                .foregroundStyle(workspace.activeTool == tool ? Color.accentColor : .primary)
                .background(workspace.activeTool == tool ? Color.accentColor.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:8))
        }.accessibilityLabel(Text(LocalizedStringKey(tool.title)))
            .accessibilityValue(Text(LocalizedStringKey(workspace.activeTool == tool ? "Activé" : "Désactivé")))
            .accessibilityIdentifier("tool-\(tool.rawValue)").help(L10n.tr(tool.title))
    }

    @ViewBuilder private var configuration: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(LocalizedStringKey(workspace.activeTool.title)).font(.headline)
            if editingText { TextStyleControls(style:$workspace.textStyle) }
            else if workspace.activeTool == .signature { Button("Configurer la signature") { settings = false; signature() } }
            else if workspace.activeTool == .insertImage { Button("Choisir une image",action:pickImage) }
            else if workspace.activeTool == .date { DatePicker("Date",selection:$workspace.stampDate,displayedComponents:.date) }
            else if workspace.activeTool == .stamp { TextField("Texte du tampon",text:$workspace.stampText).textFieldStyle(.roundedBorder) }
            else if workspace.activeTool == .erase {
                Picker("Mode de gomme",selection:$workspace.eraserMode) { ForEach(EraserMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) } }.pickerStyle(.segmented)
                Slider(value:$workspace.eraserSize,in:4...30) { Text("Taille de la gomme") }
            } else if showsAppearanceControls {
                ColorPicker("Couleur",selection:$workspace.inkColor,supportsOpacity:false)
                Slider(value:$workspace.lineWidth,in:0.5...24,step:0.5) { Text("Épaisseur") }
                Text(L10n.format("Épaisseur : %.1f pt",Double(workspace.lineWidth))).font(.caption)
                Slider(value:$workspace.opacity,in:0.25...1) { Text("Opacité") }
                Text(L10n.format("Opacité : %lld %%",Int(workspace.opacity*100))).font(.caption)
                if workspace.activeTool == .pen {
                    Toggle("Pression du Pencil",isOn:$workspace.pressureSensitive).disabled(workspace.convertHandwriting)
                    Toggle("Convertir l’écriture en texte",isOn:$workspace.convertHandwriting)
                }
                if workspace.activeTool.isShape || workspace.activeTool == .move {
                    Picker("Style de bord",selection:$workspace.shapeStyle.pattern) { ForEach(StrokePattern.allCases) { Text(LocalizedStringKey($0.title)).tag($0) } }
                    if workspace.activeTool == .arrow || (workspace.activeTool == .move && workspace.selectedAnnotation?.endLineStyle == .closedArrow) {
                        Toggle("Double flèche",isOn:$workspace.shapeStyle.doubleArrow)
                    }
                    if [.rectangle,.oval].contains(workspace.activeTool) || (workspace.activeTool == .move && ["Square","Circle"].contains(workspace.selectedAnnotation?.type ?? "")) {
                        Toggle("Remplissage",isOn:$workspace.shapeStyle.filled)
                    }
                }
            }
        }
    }
}

extension CanvasTool {
    var instruction: String {
        switch self {
        case .read: return "Faites défiler, zoomez ou sélectionnez du texte."
        case .highlight: return "Glissez sur le texte pour le surligner."
        case .underline: return "Glissez sur le texte pour le souligner."
        case .strikeOut: return "Glissez sur le texte pour le barrer."
        case .text: return "Touchez ou tracez un cadre, puis écrivez directement sur la page."
        case .note: return "Touchez la page et écrivez votre note."
        case .signature: return "Touchez la page pour placer votre signature."
        case .pen: return "Dessinez sur la page avec le doigt ou le Pencil."
        case .freeHighlighter: return "Tracez librement le marqueur sur la page."
        case .rectangle, .oval, .line, .arrow: return "Tracez la forme directement sur la page."
        case .move: return "Déplacez une annotation. Tirez la poignée d’une zone de texte pour la redimensionner."
        case .erase: return "Glissez la gomme sur les traits."
        case .replaceText: return "Touchez une ligne pour remplacer son contenu PDF."
        case .targetImage: return "Touchez l’image PDF à remplacer."
        case .insertImage: return "Choisissez une image, puis touchez la page pour la placer."
        case .link: return "Tracez la zone du lien."
        case .redact: return "Tracez la zone à biffer."
        case .date, .checkmark, .cross, .stamp: return "Touchez la page pour placer la marque."
        }
    }
}
