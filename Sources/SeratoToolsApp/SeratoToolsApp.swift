import AppKit
import SwiftUI
import SeratoToolsCore

final class SeratoToolsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Ensure the first window becomes key/main after launch.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
        }
    }
}

@main
struct SeratoToolsApp: App {
    @NSApplicationDelegateAdaptor(SeratoToolsAppDelegate.self) private var appDelegate

    @StateObject private var libraryService: LibraryService
    @StateObject private var hiddenCrateStore: HiddenCrateStore
    @StateObject private var crateHierarchy: CrateHierarchyViewModel
    @StateObject private var smartCrateHierarchy: CrateHierarchyViewModel
    @StateObject private var missingTracksService: MissingTracksService

    init() {
        let libraryDirectory = SeratoLibraryLocator.discoverLibraryDirectory()
        print("SeratoTools library directory: \(libraryDirectory.path)")

        let library = LibraryService(libraryDirectory: libraryDirectory)
        let hiddenStore = HiddenCrateStore()
        _libraryService = StateObject(wrappedValue: library)
        _hiddenCrateStore = StateObject(wrappedValue: hiddenStore)
        _crateHierarchy = StateObject(
            wrappedValue: CrateHierarchyViewModel(hiddenStore: hiddenStore, allowsDelete: true)
        )
        _smartCrateHierarchy = StateObject(
            wrappedValue: CrateHierarchyViewModel(hiddenStore: hiddenStore, allowsDelete: false)
        )
        _missingTracksService = StateObject(
            wrappedValue: MissingTracksService(
                rootDirectory: SeratoLibraryLocator.rootDirectory(for: libraryDirectory),
                databaseFileURL: library.databaseFile
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(crateHierarchy: crateHierarchy, smartCrateHierarchy: smartCrateHierarchy)
                .environmentObject(libraryService)
                .environmentObject(hiddenCrateStore)
                .environmentObject(missingTracksService)
        }
    }
}
