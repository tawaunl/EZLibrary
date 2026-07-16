import AppKit
import SwiftUI
import SeratoToolsCore

@MainActor
final class SeratoToolsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Apply the saved light/dark/system appearance preference.
        ThemeController.shared.applyStored()

        // Ensure the first window becomes key/main after launch.
        DispatchQueue.main.async { [self] in
            if let window = NSApp.windows.first {
                self.configureStandardWindowChrome(for: window)
                self.installThemeAccessory(on: window)
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
        }
    }

    private func installThemeAccessory(on window: NSWindow) {
        let alreadyInstalled = window.titlebarAccessoryViewControllers
            .contains { $0 is ThemeTitlebarAccessoryController }
        guard !alreadyInstalled else { return }
        window.addTitlebarAccessoryViewController(ThemeTitlebarAccessoryController())
    }

    private func configureStandardWindowChrome(for window: NSWindow) {
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
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
    @StateObject private var updateChecker = UpdateCheckViewModel()
    @ObservedObject private var themeController = ThemeController.shared

    init() {
        SeratoFeatureFlags.applyDisableAutoRenameMigrationIfNeeded()

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
                .sheet(isPresented: $updateChecker.isPresented) {
                    UpdateCheckView(viewModel: updateChecker)
                }
                .task {
                    await updateChecker.runAutomaticCheckIfDue()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateChecker.startCheck()
                }
            }
            CommandGroup(before: .toolbar) {
                Picker("Appearance", selection: Binding(
                    get: { themeController.current },
                    set: { themeController.set($0) }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Divider()
            }
        }
    }
}
