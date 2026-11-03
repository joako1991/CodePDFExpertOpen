import SwiftUI

@main
struct PaperStudioApp: App {
    @StateObject private var library = DocumentLibrary()
    @AppStorage("appLanguage") private var language: AppLanguage = .preferred
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library).tint(.indigo)
                .environment(\.locale, Locale(identifier: language.rawValue))
        }
    }
}
