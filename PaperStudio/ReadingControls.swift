// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AVFoundation

@MainActor
final class ReadingSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string:text)
        utterance.voice = AVSpeechSynthesisVoice(language:AppLanguage.current.rawValue)
        speaking = true; synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at:.immediate); speaking = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking = false }
    }
}

struct ReadingControls: View {
    @ObservedObject var workspace: PDFWorkspace
    @ObservedObject var speaker: ReadingSpeaker
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Paramètres d’affichage").font(.headline)
            Picker("Disposition",selection:$workspace.reading.layout) {
                ForEach(ReadingLayout.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.pickerStyle(.menu)
            HStack { Image(systemName:"sun.min"); Slider(value:$workspace.reading.brightness,in:-0.3...0.3) { Text("Luminosité") }; Image(systemName:"sun.max") }
            Picker("Thème",selection:$workspace.reading.theme) {
                ForEach(ReadingTheme.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Cacher les marges",isOn:$workspace.reading.hideMargins)
            Toggle("Synthèse vocale",isOn:Binding(get:{speaker.speaking},set:{ enabled in
                if enabled { speaker.speak(workspace.page?.string ?? "") } else { speaker.stop() }
            }))
            Toggle("Maintenir l’iPad éveillé",isOn:$workspace.reading.keepAwake)
        }.padding().frame(width:320)
    }
}

struct ReadingThemeModifier: ViewModifier {
    let settings: ReadingSettings
    func body(content: Content) -> some View {
        content.colorMultiply(settings.theme == .sepia ? Color(red:1,green:0.94,blue:0.79) : .white)
            .overlay { Color.white.opacity(settings.theme == .night ? 1 : 0).blendMode(.difference).allowsHitTesting(false) }
            .compositingGroup().brightness(settings.brightness)
    }
}
