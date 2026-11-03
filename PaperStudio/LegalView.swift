// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct LegalView: View {
    private var upstream: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Bundle.main.bundleURL.appendingPathComponent("Legal/MuPDFNotices"),
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Paper Studio 0.1 · MuPDF \(MuPDFEngine.version)") {
                    Text("Application libre sous GNU AGPL version 3 ou ultérieure. Sans garantie. Vous pouvez la modifier et la redistribuer selon les termes de cette licence.")
                    Link("Code source et instructions de compilation", destination: URL(string: "https://github.com/joako1991/CodePDFExpertOpen")!)
                    NavigationLink("Licence AGPL complète") { legalText("LICENSE") }
                    NavigationLink("Attributions") { legalText("NOTICE") }
                }
                Section("Licences des dépendances et polices") {
                    ForEach(upstream, id: \.self) { url in
                        NavigationLink(url.deletingPathExtension().lastPathComponent) {
                            ScrollView { Text((try? String(contentsOf: url, encoding: .utf8)) ?? "Texte indisponible")
                                .font(.footnote.monospaced()).textSelection(.enabled).padding() }
                        }
                    }
                }
            }.navigationTitle("À propos et licences")
        }
    }

    private func legalText(_ name: String) -> some View {
        ScrollView {
            Text(Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Legal")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Texte indisponible")
                .font(.footnote.monospaced()).textSelection(.enabled).padding()
        }.navigationTitle(name == "LICENSE" ? "AGPL-3.0-or-later" : "Attributions")
    }
}
