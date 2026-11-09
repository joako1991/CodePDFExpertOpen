// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PDFKit

private struct AnnotationRow: Identifiable {
    let id: String
    let page: Int
    let annotations: [PDFAnnotation]
    let title: String
}

private struct OutlineRow: Identifiable {
    let id: String
    let depth: Int
    let label: String
    let destination: PDFDestination?
}

struct DocumentPanelView<Pages: View>: View {
    @ObservedObject var workspace: PDFWorkspace
    let pages: Pages
    @State private var annotations: [AnnotationRow] = []
    @State private var outline: [OutlineRow] = []
    @State private var query = ""
    @State private var loading = false
    private var refresh: String { "\(workspace.document.map { String(describing:ObjectIdentifier($0)) } ?? "none")-\(workspace.revision)-\(workspace.panel.rawValue)" }

    var body: some View {
        VStack(spacing:0) {
            Picker("Panneau du document",selection:$workspace.panel) {
                ForEach(DocumentPanel.allCases) { Label(LocalizedStringKey($0.title),systemImage:$0.symbol).labelStyle(.iconOnly).tag($0) }
            }.pickerStyle(.segmented).padding(8)
            if workspace.panel == .pages { pages }
            else if workspace.panel == .annotations {
                TextField("Rechercher des annotations",text:$query).textFieldStyle(.roundedBorder).padding(8)
                List {
                    if loading { ProgressView() }
                    ForEach(annotations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { row in
                        Button { if let annotation = row.annotations.first { workspace.selectAnnotation(annotation) } } label: {
                            VStack(alignment:.leading,spacing:5) {
                                Text("Page \(row.page+1)").font(.caption).foregroundStyle(.secondary)
                                Text(row.title).font(.caption).lineLimit(2)
                                if row.annotations.first?.type == "Ink" { InkAnnotationPreview(annotations:row.annotations).frame(height:38) }
                            }.foregroundStyle(.primary)
                        }
                    }
                    if !loading && annotations.isEmpty { Text("Aucune annotation") }
                }.listStyle(.plain)
            } else if workspace.panel == .bookmarks {
                List {
                    ForEach(workspace.bookmarks.sorted(),id:\.self) { index in
                        Button("Page \(index+1)") { workspace.go(to:index) }
                    }
                    if workspace.bookmarks.isEmpty { Text("Aucun signet") }
                }.listStyle(.plain)
            } else {
                List(outline) { row in
                    Button { if let destination = row.destination { workspace.finishInteraction(); workspace.pdfView?.go(to:destination) } } label: {
                        Text(row.label).font(.caption).padding(.leading,CGFloat(row.depth)*10)
                    }.disabled(row.destination == nil)
                }.listStyle(.plain)
                if outline.isEmpty { Text("Aucun sommaire").font(.caption).padding() }
            }
        }.background(Color(uiColor:.secondarySystemBackground))
            .task(id:refresh) { await reload() }
    }

    @MainActor private func reload() async {
        guard let document = workspace.document else { return }
        if workspace.panel == .outline {
            var rows: [OutlineRow] = [], seen: Set<ObjectIdentifier> = []
            func visit(_ node: PDFOutline, depth: Int, path: String) {
                guard depth < 64, seen.insert(ObjectIdentifier(node)).inserted else { return }
                for index in 0..<node.numberOfChildren {
                    guard let child = node.child(at:index) else { continue }
                    let key = path+"-\(index)"
                    rows.append(OutlineRow(id:key,depth:depth,label:child.label ?? "",destination:child.destination ?? (child.action as? PDFActionGoTo)?.destination))
                    visit(child,depth:depth+1,path:key)
                }
            }
            if let root = document.outlineRoot { visit(root,depth:0,path:"root") }
            outline = rows
        } else if workspace.panel == .annotations {
            loading = true
            var rows: [AnnotationRow] = []
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return }
                let page = document.page(at:index)
                var groups: [String:[PDFAnnotation]] = [:], order: [String] = []
                for annotation in page?.annotations ?? [] where annotation.type != "Widget" {
                    let name = annotation.value(forAnnotationKey:.name) as? String ?? ""
                    let key = name.hasPrefix("PaperStudio-") ? name.split(separator:"-").dropLast().joined(separator:"-") : String(describing:ObjectIdentifier(annotation))
                    if groups[key] == nil { order.append(key) }
                    groups[key,default:[]].append(annotation)
                }
                rows += order.map { key in
                    let items = groups[key]!, annotation = items[0]
                    let types = ["Highlight":"Surligner","Underline":"Souligner","StrikeOut":"Barrer","Square":"Rectangle","Circle":"Ellipse","Line":"Ligne","Ink":"Dessiner","Link":"Lien","Stamp":"Tampon"]
                    var title = annotation.contents?.isEmpty == false ? annotation.contents! : L10n.tr(types[annotation.type ?? ""] ?? "Annotation sélectionnée")
                    if ["Highlight","Underline","StrikeOut"].contains(annotation.type ?? ""), let snippet = page?.selection(for:annotation.bounds)?.string, !snippet.isEmpty { title = snippet }
                    if annotation.type == "Link" { title = annotation.url?.absoluteString ?? title }
                    return AnnotationRow(id:"\(index)-\(key)",page:index,annotations:items,title:title)
                }
                if index % 16 == 0 { await Task.yield() }
            }
            guard !Task.isCancelled else { return }
            annotations = rows; loading = false
        }
    }
}

private struct InkAnnotationPreview: View {
    let annotations: [PDFAnnotation]
    var body: some View {
        Canvas { context,size in
            guard let bounds = annotations.first?.bounds, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width/bounds.width,size.height/bounds.height)
            let transform = CGAffineTransform(a:scale,b:0,c:0,d:-scale,tx:0,ty:size.height)
            for annotation in annotations {
                for path in annotation.paths ?? [] {
                    context.stroke(Path(path.cgPath).applying(transform),with:.color(Color(annotation.color.withAlphaComponent(annotation.appearanceOpacity))),lineWidth:max(1,(annotation.border?.lineWidth ?? 1)*scale))
                }
            }
        }
    }
}
