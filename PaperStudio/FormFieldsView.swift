import SwiftUI
import PDFKit

struct FormFieldsView: View {
    @ObservedObject var workspace: PDFWorkspace
    @State private var drafts: [Int: String] = [:]
    private var fields: [(page: Int, annotation: PDFAnnotation)] {
        guard let document = workspace.document else { return [] }
        return (0..<document.pageCount).flatMap { index in
            (document.page(at: index)?.annotations ?? [])
                .filter { $0.type == "Widget" && ($0.widgetFieldType == .text || $0.widgetFieldType == .choice) }
                .map { (page: index, annotation: $0) }
        }
    }

    var body: some View {
        Form {
            if fields.isEmpty {
                Text("Aucun champ texte ou liste AcroForm détecté. Les formulaires XFA ne sont pas pris en charge.")
            }
            ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                Section("\(field.annotation.fieldName ?? "Champ \(index + 1)") · page \(field.page + 1)") {
                    if let choices = field.annotation.choices, !choices.isEmpty {
                        Picker("Valeur", selection: binding(index, field.annotation)) {
                            Text("—").tag("")
                            ForEach(Array(Set(choices)).sorted(), id: \.self) { value in Text(value).tag(value) }
                        }
                    } else {
                        TextField("Valeur", text: binding(index, field.annotation), axis: .vertical)
                    }
                    Button("Appliquer au formulaire") {
                        workspace.setFormValue(field.annotation, value: drafts[index] ?? field.annotation.widgetStringValue ?? "")
                    }.disabled(field.annotation.isReadOnly)
                }.disabled(field.annotation.isReadOnly)
            }
            Section {
                Text("Les cases à cocher et boutons radio se remplissent directement dans la page. Enregistrez le document après avoir rempli le formulaire.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Remplir le formulaire")
    }

    private func binding(_ index: Int, _ annotation: PDFAnnotation) -> Binding<String> {
        Binding(get: { drafts[index] ?? annotation.widgetStringValue ?? "" }, set: { drafts[index] = $0 })
    }
}
