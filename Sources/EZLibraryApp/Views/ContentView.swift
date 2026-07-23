// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import AppKit
import EZLibraryCore

extension Notification.Name {
    /// Posted by the menu-bar "Settings…" command to open the settings sheet.
    static let openEZLibrarySettings = Notification.Name("openEZLibrarySettings")
}

enum SidebarSection: Hashable {
    case tracks
    case duplicates
    case playlistMatch
    case addMusic
    case youtubeRip
    case crates
    case missingTracks
    case backup
    case libraryConsolidation
}

struct ContentView: View {
    private enum QuickTrackDeleteAction {
        case fromLibrary
        case fromComputer

        var title: String {
            switch self {
            case .fromLibrary:
                return "Delete From Library"
            case .fromComputer:
                return "Delete From Computer"
            }
        }
    }

    private static let confirmDeleteActionsDefaultsKey = "SeratoToolsConfirmTrackDeleteActions"
    private static let recentLibraryFoldersDefaultsKey = "SeratoToolsRecentLibraryFolders"
    private static let recentCentralFoldersDefaultsKey = "SeratoToolsRecentCentralFolders"

    private let sidebarWidth: CGFloat = 220
    private let middlePaneWidth: CGFloat = 320

    @EnvironmentObject private var libraryService: LibraryService
    @EnvironmentObject private var dependencyReadiness: DependencyReadinessModel
    @ObservedObject var crateHierarchy: CrateHierarchyViewModel
    @ObservedObject var smartCrateHierarchy: CrateHierarchyViewModel

    @State private var selectedSection: SidebarSection? = .tracks
    @State private var selectedCrateNode: CrateNode?
    @State private var loadErrorMessage: String?
    @State private var libraryPathDraft = ""

    @State private var pendingTrackDeleteSelection: [Track] = []
    @State private var showTrackDeleteDialog = false
    @State private var trackDeleteErrorMessage: String?
    @State private var crateListFilterMode: CrateListFilterMode = .all
    @State private var quickTrackDeleteAction: QuickTrackDeleteAction?
    @State private var showQuickTrackDeleteConfirmation = false
    @State private var showSettingsSheet = false
    @State private var metadataSaveMessage: String?
    @State private var metadataSaveMessageTask: Task<Void, Never>?
    @State private var activeAudioTrack: Track?
    @State private var activeAudioTrackList: [Track] = []
    @State private var audioActivationToken = 0
    @AppStorage(Self.confirmDeleteActionsDefaultsKey) private var confirmDeleteActions = true
    @AppStorage(SeratoFeatureFlags.mainMusicFolderDefaultsKey) private var centralMusicFolderPath = ""

    private var totalCratesCount: Int {
        libraryService.crates.count
    }

    private var totalTracksInCratesCount: Int {
        libraryService.tracksInCratesCount
    }

    private var centralMusicFolderStartURL: URL {
        let trimmed = centralMusicFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var centralMusicFolderSuggestions: [String] {
        var suggestions: [String] = []
        let central = centralMusicFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !central.isEmpty {
            suggestions.append(central)
        }
        suggestions.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true).path
        )
        let root = libraryService.rootDirectory.standardizedFileURL
        if root.path != "/" {
            suggestions.append(root.appendingPathComponent("Music", isDirectory: true).path)
        }
        return suggestions
    }

    private var smartCratesCount: Int {
        libraryService.smartCrates.count
    }

    private var hiddenCratesCount: Int {
        Set((crateHierarchy.hiddenNodes + smartCrateHierarchy.hiddenNodes).map(\.id)).count
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            DependencyReadinessBanner(model: dependencyReadiness)
            HSplitView {
                sidebar
                middleContent
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }

            if let activeAudioTrack {
                Divider()
                HStack {
                    TrackAudioPlayerPanel(
                        track: activeAudioTrack,
                        activationToken: audioActivationToken,
                        onPrevious: canPlayPreviousAudioTrack ? { playAdjacentAudioTrack(offset: -1) } : nil,
                        onNext: canPlayNextAudioTrack ? { playAdjacentAudioTrack(offset: 1) } : nil
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            }
        }
    }

    /// The main stack plus its lifecycle/reactive modifiers, split off from
    /// `body` so the type-checker handles this chain and the sheet/dialog
    /// chain as two smaller expressions instead of one very slow one.
    private var mainStackWithLifecycle: some View {
        mainStack
            .task {
                libraryPathDraft = libraryService.libraryDirectory.path
                await reloadLibraryAsync()
            }
            .onChange(of: selectedSection) {
                resetTransientFilters()
            }
            .onChange(of: selectedCrateNode?.id) {
                if selectedSection == .crates {
                    crateListFilterMode = .all
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                resetTransientFilters()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openEZLibrarySettings)) { _ in
                showSettingsSheet = true
            }
    }

    var body: some View {
        mainStackWithLifecycle
        .sheet(isPresented: $showSettingsSheet) {
            AppSettingsSheet()
        }
        .confirmationDialog(
            "Delete Selected Tracks",
            isPresented: $showTrackDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("Delete From Crate", role: .destructive) {
                // Not applicable in the global Tracks view.
            }
            .disabled(true)

            Button("Delete From Library", role: .destructive) {
                deleteSelectedTracksFromLibrary()
            }

            Button("Delete From Computer", role: .destructive) {
                deleteSelectedTracksFromComputer()
            }

            Button("Cancel", role: .cancel) {
                clearPendingTrackDelete()
            }
        } message: {
            Text("Choose how to delete \(pendingTrackDeleteSelection.count) selected track\(pendingTrackDeleteSelection.count == 1 ? "" : "s").")
        }
        .alert(
            "Couldn't Complete Operation",
            isPresented: Binding(get: { trackDeleteErrorMessage != nil }, set: { if !$0 { trackDeleteErrorMessage = nil } })
        ) {
            Button("OK") { trackDeleteErrorMessage = nil }
        } message: {
            Text(trackDeleteErrorMessage ?? "")
        }
        .confirmationDialog(
            "Confirm Delete",
            isPresented: $showQuickTrackDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let action = quickTrackDeleteAction {
                Button(action.title, role: .destructive) {
                    executeQuickTrackDelete(action)
                }
            }
            Button("Turn Off Confirmations") {
                confirmDeleteActions = false
                if let action = quickTrackDeleteAction {
                    executeQuickTrackDelete(action)
                }
            }
            Button("Cancel", role: .cancel) {
                quickTrackDeleteAction = nil
            }
        } message: {
            if let action = quickTrackDeleteAction {
                Text("\(action.title) for \(pendingTrackDeleteSelection.count) selected track\(pendingTrackDeleteSelection.count == 1 ? "" : "s")?")
            }
        }
        .overlay(alignment: .topTrailing) {
            if let metadataSaveMessage {
                Text(metadataSaveMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.14))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.green.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
        }
    }

    private var cratesStatsHeader: some View {
        HStack(spacing: 10) {
            crateStatTag(
                title: "Crates",
                value: totalCratesCount,
                isActive: crateListFilterMode == .all,
                action: {
                    crateListFilterMode = .all
                    selectedCrateNode = nil
                }
            )
            crateStatTag(
                title: "Tracks In Crates",
                value: totalTracksInCratesCount,
                action: {
                    crateListFilterMode = .all
                    selectedCrateNode = nil
                }
            )
            crateStatTag(
                title: "Smart Crates",
                value: smartCratesCount,
                isActive: crateListFilterMode == .smartOnly,
                action: {
                    crateListFilterMode = crateListFilterMode == .smartOnly ? .all : .smartOnly
                    selectedCrateNode = nil
                }
            )
            crateStatTag(
                title: "Hidden",
                value: hiddenCratesCount,
                isActive: crateListFilterMode == .hiddenOnly,
                action: {
                    crateListFilterMode = crateListFilterMode == .hiddenOnly ? .all : .hiddenOnly
                    selectedCrateNode = nil
                }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .glowCardStyle(radius: 8, opacity: 0.06)
    }

    private func crateStatTag(
        title: String,
        value: Int,
        isActive: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? .white.opacity(0.92) : .secondary)
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isActive ? .white : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isActive ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
        )

        return Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Label("Tracks & Tags", systemImage: "music.note.list").tag(SidebarSection.tracks)
            Label("Duplicates", systemImage: "rectangle.on.rectangle").tag(SidebarSection.duplicates)
            Label("PlaylistMatch", systemImage: "music.quarternote.3").tag(SidebarSection.playlistMatch)
            Label("Add Music", systemImage: "plus.square.on.square").tag(SidebarSection.addMusic)
            Label("Download Audio", systemImage: "arrow.down.circle").tag(SidebarSection.youtubeRip)
            Label("Crates", systemImage: "square.stack").tag(SidebarSection.crates)
            Label("Missing Tracks", systemImage: "exclamationmark.triangle").tag(SidebarSection.missingTracks)
            Label("Backup", systemImage: "externaldrive.badge.plus").tag(SidebarSection.backup)
            Label("Library Consolidation", systemImage: "arrow.triangle.merge").tag(SidebarSection.libraryConsolidation)
        }
        .frame(minWidth: sidebarWidth, idealWidth: sidebarWidth, maxWidth: sidebarWidth)
    }

    @ViewBuilder
    private var middleContent: some View {
        switch selectedSection {
        case .tracks:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FolderDropdownControl(
                        label: "Library directory",
                        path: $libraryPathDraft,
                        recentsKey: Self.recentLibraryFoldersDefaultsKey,
                        browsePrompt: "Use Library",
                        browseStartURL: URL(fileURLWithPath: libraryPathDraft.isEmpty ? libraryService.libraryDirectory.path : libraryPathDraft),
                        suggestedPaths: [libraryService.libraryDirectory.path],
                        onPathChanged: applyLibraryDirectory
                    )
                    Button("Apply") { applyLibraryDirectory() }
                        .help("Load the Serato library from the directory shown above.")
                    Button("Reload") { reloadLibrary() }
                        .help("Re-read tracks and crates from the current library directory.")
                    Button("Settings…") { showSettingsSheet = true }
                        .help("Open settings: Discogs/AcoustID API keys, automation options, and more.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                FolderDropdownControl(
                    label: "Central music folder",
                    path: $centralMusicFolderPath,
                    recentsKey: Self.recentCentralFoldersDefaultsKey,
                    browsePrompt: "Use Folder",
                    browseStartURL: centralMusicFolderStartURL,
                    suggestedPaths: centralMusicFolderSuggestions,
                    onPathChanged: {}
                )
                .help("The folder your library is consolidated into. New downloads and imported/purchased tracks are moved here automatically.")
                .padding(.horizontal, 8)

                if let loadErrorMessage {
                    Text("Library load failed: \(loadErrorMessage)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                }

                TracksAndTagsView(
                    onApplyMetadata: { track, metadata in
                        try saveTrackMetadataEdit(track: track, metadata: metadata)
                    },
                    onApplyMetadataBatch: { updates in
                        try saveTrackMetadataEditsBatch(updates)
                    },
                    onTrackActivated: { track, list in
                        activateAudioTrack(track, in: list)
                    },
                    onDeleteRequested: { selected in
                        pendingTrackDeleteSelection = selected
                        showTrackDeleteDialog = true
                    },
                    onDeleteFromLibrary: { selected in
                        pendingTrackDeleteSelection = selected
                        performOrConfirmQuickTrackDelete(.fromLibrary)
                    },
                    onDeleteFromComputer: { selected in
                        pendingTrackDeleteSelection = selected
                        performOrConfirmQuickTrackDelete(.fromComputer)
                    }
                )
            }
        case .duplicates:
            DuplicateTracksView(onLibraryChanged: reloadLibrary)
        case .playlistMatch:
            PlaylistMatchView(onLibraryChanged: reloadLibrary)
        case .addMusic:
            AddMusicView(onLibraryChanged: reloadLibrary)
        case .youtubeRip:
            YouTubeRipView(onLibraryChanged: reloadLibrary)
        case .missingTracks:
            MissingTracksView()
        case .backup:
            LibraryBackupView()
        case .libraryConsolidation:
            LibraryConsolidationView(onLibraryChanged: reloadLibrary)
        case .crates:
            VStack(alignment: .leading, spacing: 12) {
                SectionHeaderCard(
                    title: "Crates",
                    description: "Review nested crates, inspect the tree structure, and manage hidden or smart playlists from one place.",
                    icon: "square.stack"
                )

                cratesStatsHeader

                HStack(spacing: 12) {
                    CrateTreeView(
                        crateHierarchy: crateHierarchy,
                        smartCrateHierarchy: smartCrateHierarchy,
                        selectedNode: $selectedCrateNode,
                        listFilterMode: crateListFilterMode,
                        onCratesChanged: reloadLibrary
                    )
                    .frame(minWidth: middlePaneWidth, idealWidth: middlePaneWidth, maxWidth: middlePaneWidth)

                    Group {
                        if let node = selectedCrateNode {
                            CrateDetailView(
                                node: node,
                                filterMode: crateListFilterMode,
                                onCratesChanged: reloadLibrary,
                                onTrackActivated: { track, list in
                                    activateAudioTrack(track, in: list)
                                }
                            )
                        } else {
                            Text("Select an item")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 8)
        case nil:
            Text("Select a section")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func activateAudioTrack(_ track: Track, in list: [Track]) {
        activeAudioTrack = track
        activeAudioTrackList = list
        audioActivationToken += 1
    }

    private var activeAudioTrackIndex: Int? {
        guard let activeAudioTrack else { return nil }
        return activeAudioTrackList.firstIndex { $0.seratoStoredPath == activeAudioTrack.seratoStoredPath }
    }

    private var canPlayPreviousAudioTrack: Bool {
        guard let index = activeAudioTrackIndex else { return false }
        return index > 0
    }

    private var canPlayNextAudioTrack: Bool {
        guard let index = activeAudioTrackIndex else { return false }
        return index < activeAudioTrackList.count - 1
    }

    private func playAdjacentAudioTrack(offset: Int) {
        guard let index = activeAudioTrackIndex else { return }
        let newIndex = index + offset
        guard activeAudioTrackList.indices.contains(newIndex) else { return }
        activeAudioTrack = activeAudioTrackList[newIndex]
        audioActivationToken += 1
    }

    private func reloadLibrary() {
        // Kicks off the off-main parse; call sites (child "library changed"
        // callbacks, buttons) stay synchronous.
        Task { await reloadLibraryAsync() }
    }

    /// Reloads the library with the heavy parse performed off the main actor
    /// (see `LibraryService.reloadAsync`), then refreshes the crate trees and
    /// selection on the main actor once results arrive.
    private func reloadLibraryAsync() async {
        let previousSelectedNodeID = selectedCrateNode?.id

        await libraryService.reloadAsync()

        if let message = libraryService.reloadErrorMessage {
            loadErrorMessage = message
            crateHierarchy.rebuild(from: [])
            smartCrateHierarchy.rebuild(from: [])
            selectedCrateNode = nil
        } else {
            loadErrorMessage = nil
            crateHierarchy.rebuild(from: libraryService.crates)
            smartCrateHierarchy.rebuild(from: libraryService.smartCrates)
            selectedCrateNode = refreshedSelectedCrateNode(previousID: previousSelectedNodeID)
        }
    }

    private func refreshedSelectedCrateNode(previousID: String?) -> CrateNode? {
        guard let previousID else { return nil }

        let rebuilt = CrateHierarchy.build(from: libraryService.crates + libraryService.smartCrates)
        return findCrateNode(withID: previousID, in: rebuilt)
    }

    private func findCrateNode(withID nodeID: String, in nodes: [CrateNode]) -> CrateNode? {
        for node in nodes {
            if node.id == nodeID {
                return node
            }
            if let child = findCrateNode(withID: nodeID, in: node.children) {
                return child
            }
        }
        return nil
    }

    private func applyLibraryDirectory() {
        let path = libraryPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        libraryService.setLibraryDirectory(url)
        UserDefaults.standard.set(path, forKey: SeratoLibraryLocator.libraryDirectoryDefaultsKey)
        reloadLibrary()
    }

    private func clearPendingTrackDelete() {
        pendingTrackDeleteSelection = []
    }

    private func resetTransientFilters() {
        crateListFilterMode = .all
    }

    private func performOrConfirmQuickTrackDelete(_ action: QuickTrackDeleteAction) {
        guard !pendingTrackDeleteSelection.isEmpty else { return }
        if confirmDeleteActions {
            quickTrackDeleteAction = action
            showQuickTrackDeleteConfirmation = true
        } else {
            executeQuickTrackDelete(action)
        }
    }

    private func executeQuickTrackDelete(_ action: QuickTrackDeleteAction) {
        quickTrackDeleteAction = nil
        switch action {
        case .fromLibrary:
            deleteSelectedTracksFromLibrary()
        case .fromComputer:
            deleteSelectedTracksFromComputer()
        }
    }

    private func deleteSelectedTracksFromLibrary() {
        do {
            let removedPaths = Set(pendingTrackDeleteSelection.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            reloadLibrary()
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedTracksFromComputer() {
        do {
            for track in pendingTrackDeleteSelection {
                guard FileManager.default.fileExists(atPath: track.fileURL.path) else { continue }
                _ = try FileManager.default.trashItem(at: track.fileURL, resultingItemURL: nil)
            }

            let removedPaths = Set(pendingTrackDeleteSelection.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            reloadLibrary()
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
    }

    private func removeTracksFromLibraryMetadata(paths: Set<String>) throws {
        guard !paths.isEmpty else { return }

        let databaseURL = libraryService.databaseFile
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseURL)
        }

        let databaseData = try Data(contentsOf: databaseURL)
        let rewritten = SeratoDatabaseWriter.removingPaths(paths, in: databaseData)
        if rewritten.didRewrite {
            try AtomicFileWriter.write(rewritten.data, to: databaseURL)
        }

        for crate in libraryService.crates {
            guard crate.fileURL?.pathExtension.lowercased() == "crate" else { continue }
            if crate.trackPaths.contains(where: { paths.contains($0) }) {
                let rewrittenPaths = crate.trackPaths.filter { !paths.contains($0) }
                _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: rewrittenPaths)
            }
        }
    }

    private func saveTrackMetadataEdit(track: Track, metadata: SeratoTrackMetadataUpdate) throws {
        let renameEnabled = SeratoFeatureFlags.isAutoRenameFromMetadataEnabled()
        try SeratoTrackMetadataEditor.update(
            track: track,
            metadata: metadata,
            databaseFileURL: libraryService.databaseFile,
            rewriteFilenameFromMetadata: renameEnabled
        )
        if renameEnabled {
            // Renaming rewrites crate files on disk (see `rewriteCratesPath`),
            // so a tracks-only reload leaves the in-memory crates pointing at
            // the old paths — they'd then show as "Not in local library" in
            // the crate view. Reload crates too to keep them in sync.
            reloadLibrary()
        } else {
            // Off-main so a single inline edit doesn't freeze the table on
            // large libraries; the table refreshes reactively when it lands.
            Task { await libraryService.reloadTracksOnlyAsync() }
        }
        showMetadataSaveSuccess()
    }

    private struct BulkMetadataUpdateError: LocalizedError {
        let successCount: Int
        let failedNames: [String]

        var errorDescription: String? {
            let failed = failedNames.count
            let sample = failedNames.prefix(3).joined(separator: ", ")
            let suffix = failedNames.count > 3 ? "…" : ""
            let updated = "Updated \(successCount) track\(successCount == 1 ? "" : "s")."
            return "\(updated) \(failed) couldn't be updated: \(sample)\(suffix)"
        }

        var recoverySuggestion: String? {
            "Check that those files still exist and aren't locked, then try again."
        }
    }

    private func saveTrackMetadataEditsBatch(_ updates: [(Track, SeratoTrackMetadataUpdate)]) throws {
        guard !updates.isEmpty else { return }

        // Bulk edits fill metadata across many tracks and must not rename
        // files: renaming here rewrites file paths mid-batch, which caused
        // "couldn't find this track in database V2" and file-move failures.
        // Renaming stays a single-track action, so `updateBatch` doesn't
        // support it at all.
        let result = try SeratoTrackMetadataEditor.updateBatch(
            updates: updates.map { (track: $0.0, metadata: $0.1) },
            databaseFileURL: libraryService.databaseFile
        )

        // Off-main re-parse; the failure summary below doesn't depend on it.
        Task { await libraryService.reloadTracksOnlyAsync() }

        guard result.failures.isEmpty else {
            throw BulkMetadataUpdateError(
                successCount: result.updatedTracks.count,
                failedNames: result.failures.map { $0.track.fileURL.lastPathComponent }
            )
        }

        showMetadataSaveSuccess()
    }


    private func showMetadataSaveSuccess() {
        metadataSaveMessage = "Tag updated and saved."
        metadataSaveMessageTask?.cancel()
        metadataSaveMessageTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                metadataSaveMessage = nil
                metadataSaveMessageTask = nil
            }
        }
    }
}

private struct AppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var discogsTokenInput = ""
    @State private var acoustIDKeyInput = ""
    @State private var statusMessage: String?
    @State private var validatingAcoustIDKey = false
    @State private var showHelp = false
    @AppStorage(SeratoFeatureFlags.autoRenameFromMetadataDefaultsKey) private var autoRenameFromMetadata = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))

                    Text("API Keys")
                        .font(.headline)

                    DisclosureGroup("Help: How to create and add API keys", isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Discogs (metadata lookup)")
                                .font(.caption.weight(.semibold))
                            Text("1. Create a Discogs account and create a personal access token.")
                                .font(.caption)
                            Link("Open Discogs developer settings", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                                .font(.caption)

                            Text("AcoustID (audio fingerprint)")
                                .font(.caption.weight(.semibold))
                            Text("1. Create an AcoustID account. 2. Register a new application to get a client key. 3. Use that application client key (not your account login/API token). 4. Install fpcalc (Chromaprint).")
                                .font(.caption)
                            Link("Open AcoustID new application", destination: URL(string: "https://acoustid.org/new-application")!)
                                .font(.caption)
                            Link("Install Chromaprint (Homebrew)", destination: URL(string: "https://formulae.brew.sh/formula/chromaprint")!)
                                .font(.caption)

                            Text("After creating keys, paste them below and click Save.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    Text("Discogs Token")
                        .font(.subheadline.weight(.semibold))

                    SecureField("Paste Discogs token", text: $discogsTokenInput)
                        .textFieldStyle(.roundedBorder)

                    Text("Used for Discogs metadata lookup. Stored securely in the app's settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("AcoustID Client Key (Audio Fingerprint)")
                        .font(.subheadline.weight(.semibold))

                    SecureField("Paste AcoustID client key", text: $acoustIDKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button(validatingAcoustIDKey ? "Validating..." : "Validate AcoustID Key") {
                            validateAcoustIDKey()
                        }
                        .disabled(validatingAcoustIDKey)
                        .help("Check that the AcoustID client key works for audio fingerprint lookups.")

                        if validatingAcoustIDKey {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Used for external audio fingerprint recognition. Must be an AcoustID application client key from acoustid.org/new-application. Stored securely in the app's settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Text("Automation")
                        .font(.subheadline.weight(.semibold))

                    Toggle("Auto rename files from metadata", isOn: $autoRenameFromMetadata)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Text("When saving ID3/track metadata, rename files as title-artist-album-year and update Serato database/crate paths. Leave off unless you know you need it: renaming files Serato has already analyzed can orphan the original entry and re-import the file as a new track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Clear") {
                    UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: AudioFingerprintService.tokenDefaultsKey)
                    discogsTokenInput = ""
                    acoustIDKeyInput = ""
                    statusMessage = "API tokens cleared."
                }
                .help("Remove the saved Discogs and AcoustID API keys.")

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .help("Close without saving changes.")

                Button("Save") {
                    let discogsTrimmed = discogsTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let acoustIDTrimmed = acoustIDKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

                    if discogsTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    } else {
                        UserDefaults.standard.set(discogsTrimmed, forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    }

                    if acoustIDTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: AudioFingerprintService.tokenDefaultsKey)
                    } else {
                        UserDefaults.standard.set(acoustIDTrimmed, forKey: AudioFingerprintService.tokenDefaultsKey)
                    }

                    statusMessage = "API tokens saved."
                }
                .keyboardShortcut(.defaultAction)
                .help("Save the entered API keys for online metadata and fingerprint lookups.")
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onAppear {
            initializeFeatureDefaultsIfNeeded()
            discogsTokenInput = UserDefaults.standard.string(forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey) ?? ""
            acoustIDKeyInput = UserDefaults.standard.string(forKey: AudioFingerprintService.tokenDefaultsKey) ?? ""
        }
    }

    private func initializeFeatureDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SeratoFeatureFlags.autoRenameFromMetadataDefaultsKey) == nil {
            defaults.set(false, forKey: SeratoFeatureFlags.autoRenameFromMetadataDefaultsKey)
        }
    }

    private func validateAcoustIDKey() {
        let key = acoustIDKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "Enter an AcoustID client key first."
            return
        }

        validatingAcoustIDKey = true
        statusMessage = "Validating AcoustID key..."

        Task {
            let result = await AudioFingerprintService.validateClientKey(key)
            await MainActor.run {
                validatingAcoustIDKey = false
                switch result {
                case .valid:
                    statusMessage = "AcoustID key is valid."
                case let .invalid(message):
                    statusMessage = message
                }
            }
        }
    }
}
