import AppKit
import SwiftUI
import EZLibraryCore

@MainActor
final class EZLibraryAppDelegate: NSObject, NSApplicationDelegate {
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
struct EZLibraryApp: App {
    @NSApplicationDelegateAdaptor(EZLibraryAppDelegate.self) private var appDelegate

    @StateObject private var libraryService: LibraryService
    @StateObject private var hiddenCrateStore: HiddenCrateStore
    @StateObject private var crateHierarchy: CrateHierarchyViewModel
    @StateObject private var smartCrateHierarchy: CrateHierarchyViewModel
    @StateObject private var missingTracksService: MissingTracksService
    @StateObject private var updateChecker = UpdateCheckViewModel()
    @StateObject private var dependencyReadiness = DependencyReadinessModel()
    @ObservedObject private var themeController = ThemeController.shared

    init() {
        SeratoFeatureFlags.applyDisableAutoRenameMigrationIfNeeded()

        let libraryDirectory = SeratoLibraryLocator.discoverLibraryDirectory()
        print("EZLibrary library directory: \(libraryDirectory.path)")

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
                .environmentObject(dependencyReadiness)
                .sheet(isPresented: $updateChecker.isPresented) {
                    UpdateCheckView(viewModel: updateChecker)
                }
                .task {
                    await updateChecker.runAutomaticCheckIfDue()
                }
                .task {
                    // Verify on every launch that the Homebrew-managed tools
                    // (yt-dlp, ffmpeg, fpcalc) are installed and current, and
                    // surface the readiness banner when they aren't.
                    await dependencyReadiness.checkOnLaunch()
                }
                .task {
                    // Keep a user-writable yt-dlp current in the background so
                    // downloads don't depend on the frozen bundled snapshot,
                    // and refresh the Homebrew-managed tools (ffmpeg, yt-dlp,
                    // chromaprint) so none of them go stale.
                    Task.detached(priority: .background) {
                        _ = YouTubeAudioImportService.refreshManagedYTDLPIfDue()
                        _ = HomebrewMaintenanceService.refreshIfDue()
                    }
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
