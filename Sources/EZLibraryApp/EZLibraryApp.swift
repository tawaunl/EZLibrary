// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import AppKit
import SwiftUI
import EZLibraryCore

@MainActor
final class EZLibraryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads a setting: this app has written preferences
        // under three different domain names across its history (the bundle id,
        // the executable name under `swift run`, and the old SeratoTools name),
        // so a key saved by one build is invisible to another until adopted.
        LegacyDefaultsMigration.migrateIfNeeded()

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
    @StateObject private var seratoRunning = SeratoRunningModel()
    // Owned at the app level so a bulk tag job (and the locks it holds) keeps
    // running when the user leaves the Tracks & Tags view.
    @StateObject private var backgroundTagJobs = BackgroundTagJobsModel()
    @StateObject private var tagVerificationRun = TagVerificationRunModel()
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
                .textSelection(.enabled)
                .environmentObject(libraryService)
                .environmentObject(hiddenCrateStore)
                .environmentObject(missingTracksService)
                .environmentObject(dependencyReadiness)
                .environmentObject(seratoRunning)
                .environmentObject(backgroundTagJobs)
                .environmentObject(tagVerificationRun)
                .sheet(isPresented: $updateChecker.isPresented) {
                    UpdateCheckView(viewModel: updateChecker)
                        .textSelection(.enabled)
                }
                .task {
                    // Deferred so the first paint and the initial library
                    // load (ContentView's `.task`) aren't competing with a
                    // network round-trip; the check is silent unless an
                    // update is found, so a short delay is invisible.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await updateChecker.runAutomaticCheck()
                }
                .task {
                    // Verify on every launch that the Homebrew-managed tools
                    // (yt-dlp, ffmpeg, fpcalc) are installed and current, and
                    // surface the readiness banner when they aren't. Deferred
                    // so spawning Homebrew subprocesses doesn't steal CPU from
                    // the library parse during launch.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await dependencyReadiness.checkOnLaunch()
                }
                .task {
                    // Keep a user-writable yt-dlp current in the background so
                    // downloads don't depend on the frozen bundled snapshot,
                    // and refresh the Homebrew-managed tools (ffmpeg, yt-dlp,
                    // chromaprint) so none of them go stale. Deferred further
                    // since it's the least time-sensitive launch work.
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
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
            CommandGroup(after: .newItem) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openEZLibrarySettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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
