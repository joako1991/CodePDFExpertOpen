import SwiftUI

@main
struct PaperStudioApp: App {
    @StateObject private var library = DocumentLibrary()
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library).tint(.indigo)
        }
    }
}
