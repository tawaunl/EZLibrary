import SwiftUI
import SeratoToolsCore

@main
struct SeratoToolsApp: App {
    @StateObject private var libraryService = LibraryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryService)
        }
    }
}
