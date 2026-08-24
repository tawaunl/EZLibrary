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
    @EnvironmentObject private var seratoRunning: SeratoRunningModel
    @EnvironmentObject private var backgroundTagJobs: BackgroundTagJobsModel
    @EnvironmentObject private var tagVerificationRun: TagVerificationRunModel
    @ObservedObject var crateHierarchy: CrateHierarchyViewModel
    @ObservedObject var smartCrateHierarchy: CrateHierarchyViewModel

    @State private var selectedSection: SidebarSection? = .tracks
    @State private var loadErrorMessage: String?
    @State private var libraryPathDraft = ""

    /// What the Crates section is pointed at. Defaults to All Tracks so the
    /// section opens on something useful, matching Tracks & Tags.
    @State private var crateScope: CrateBrowserScope = .allTracks

    @State private var pendingTrackDeleteSelection: [Track] = []
    @State private var showTrackDeleteDialog = false
    /// Wrapped so the sheet can be driven by `.sheet(item:)`, which hands the
    /// closure a non-optional value. The `isPresented` form needed an `if let`
    /// inside the builder, and that renders an empty sheet whenever the
    /// optional isn't populated in the same update as the flag.
    private struct BulkRenameRequest: Identifiable {
        let id = UUID()
        let preview: TrackBulkRenameService.Preview
    }

    @State private var pendingBulkRename: BulkRenameRequest?
    @State private var bulkRenameMessage: String?
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

    private var tracksNotInCratesCount: Int {
        libraryService.tracksNotInCratesCount
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

    /// A tag job keeps running when the user leaves Tracks & Tags, so it needs
    /// an indicator that follows them — with a way back to it and a way to stop.
    @ViewBuilder
    private var backgroundTagJobsBanner: some View {
        if backgroundTagJobs.isRunning {
            backgroundJobBar(text: backgroundJobText) { backgroundTagJobs.cancel() }
        } else if tagVerificationRun.isRunning, selectedSection != .tracks {
            // In Tracks & Tags the view shows its own verification banner, so
            // only surface the global one from other sections.
            backgroundJobBar(
                text: "Verifying tags: \(tagVerificationRun.completedCount) of \(tagVerificationRun.totalCount) in the background"
            ) { tagVerificationRun.cancel() }
        }
    }

    private func backgroundJobBar(text: String, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption)
            Spacer(minLength: 0)
            if selectedSection != .tracks {
                Button("Show") { selectedSection = .tracks }
                    .controlSize(.small)
            }
            Button("Stop", action: onStop)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    private var backgroundJobText: String {
        let label = backgroundTagJobs.label.isEmpty ? "Working on tags" : backgroundTagJobs.label
        if backgroundTagJobs.total > 0 {
            return "\(label): \(backgroundTagJobs.done) of \(backgroundTagJobs.total)"
        }
        return "\(label)…"
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            SeratoRunningBanner(model: seratoRunning)
            DependencyReadinessBanner(model: dependencyReadiness)
            backgroundTagJobsBanner
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
            .onChange(of: tagVerificationRun.isRunning) {
                // Lock the verification's tracks while it runs so a delete,
                // rename, or edit elsewhere can't race it.
                if tagVerificationRun.isRunning {
                    backgroundTagJobs.lock(tagVerificationRun.selectionIDs)
                } else {
                    backgroundTagJobs.release(tagVerificationRun.selectionIDs)
                }
            }
            .onChange(of: crateScope.crateNode?.id) {
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
            // Attached here rather than alongside the settings sheet in
            // `body`: SwiftUI honors one `.sheet` per view node, so stacking a
            // second on the same node presented an empty window.
            .sheet(item: $pendingBulkRename) { request in
                BulkRenamePreviewSheet(
                    preview: request.preview,
                    template: SeratoFeatureFlags.filenameFormatTemplate(),
                    skipSummary: skipSummary(for: request.preview.skips),
                    onConfirm: { performBulkRename(request.preview) },
                    onCancel: { pendingBulkRename = nil }
                )
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
            "Rename Files",
            isPresented: Binding(get: { bulkRenameMessage != nil }, set: { if !$0 { bulkRenameMessage = nil } })
        ) {
            Button("OK", role: .cancel) { bulkRenameMessage = nil }
        } message: {
            Text(bulkRenameMessage ?? "")
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
                    crateScope = .allTracks
                }
            )
            crateStatTag(
                title: "Tracks In Crates",
                value: totalTracksInCratesCount,
                action: {
                    crateListFilterMode = .all
                    crateScope = .allTracks
                }
            )
            crateStatTag(
                title: "Not In Crates",
                value: tracksNotInCratesCount,
                isActive: crateScope == .notInCrates,
                action: {
                    crateListFilterMode = .all
                    crateScope = .notInCrates
                }
            )
            crateStatTag(
                title: "Smart Crates",
                value: smartCratesCount,
                isActive: crateListFilterMode == .smartOnly,
                action: {
                    crateListFilterMode = crateListFilterMode == .smartOnly ? .all : .smartOnly
                    crateScope = .allTracks
                }
            )
            crateStatTag(
                title: "Hidden",
                value: hiddenCratesCount,
                isActive: crateListFilterMode == .hiddenOnly,
                action: {
                    crateListFilterMode = crateListFilterMode == .hiddenOnly ? .all : .hiddenOnly
                    crateScope = .allTracks
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
                    },
                    onBulkRename: { selected in
                        prepareBulkRename(for: selected)
                    },
                    onAudioEdited: {
                        reloadLibrary()
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
                        scope: $crateScope,
                        listFilterMode: crateListFilterMode,
                        onCratesChanged: reloadLibrary
                    )
                    .frame(minWidth: middlePaneWidth, idealWidth: middlePaneWidth, maxWidth: middlePaneWidth)

                    Group {
                        switch crateScope {
                        case .allTracks:
                            AllTracksBrowserView(
                                source: .allTracks,
                                onTrackActivated: { track, list in
                                    activateAudioTrack(track, in: list)
                                },
                                onCratesChanged: reloadLibrary
                            )
                        case .notInCrates:
                            AllTracksBrowserView(
                                source: .notInCrates,
                                onTrackActivated: { track, list in
                                    activateAudioTrack(track, in: list)
                                },
                                onCratesChanged: reloadLibrary
                            )
                        case let .crate(node):
                            CrateDetailView(
                                node: node,
                                filterMode: crateListFilterMode,
                                onCratesChanged: reloadLibrary,
                                onTrackActivated: { track, list in
                                    activateAudioTrack(track, in: list)
                                }
                            )
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
        let previousSelectedNodeID = crateScope.crateNode?.id

        await libraryService.reloadAsync()

        if let message = libraryService.reloadErrorMessage {
            loadErrorMessage = message
            crateHierarchy.rebuild(from: [])
            smartCrateHierarchy.rebuild(from: [])
            crateScope = .allTracks
        } else {
            loadErrorMessage = nil
            crateHierarchy.rebuild(from: libraryService.crates)
            smartCrateHierarchy.rebuild(from: libraryService.smartCrates)
            crateScope = refreshedCrateScope(previousID: previousSelectedNodeID)
        }
    }

    /// Re-resolves the selected crate against the rebuilt tree after a reload.
    /// A crate that no longer exists falls back to All Tracks rather than
    /// leaving the pane pointed at a stale node.
    private func refreshedCrateScope(previousID: String?) -> CrateBrowserScope {
        guard let previousID else { return .allTracks }

        let rebuilt = CrateHierarchy.build(from: libraryService.crates + libraryService.smartCrates)
        guard let node = findCrateNode(withID: previousID, in: rebuilt) else { return .allTracks }
        return .crate(node)
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
        // Don't delete tracks a background tag job is currently writing; drop
        // the busy ones from the selection rather than racing the job.
        if backgroundTagJobs.anyLocked(pendingTrackDeleteSelection) {
            pendingTrackDeleteSelection = backgroundTagJobs.unlockedTracks(pendingTrackDeleteSelection)
            if pendingTrackDeleteSelection.isEmpty {
                trackDeleteErrorMessage = "Those tracks are being updated by a background tag job. Try again once it finishes."
                return
            }
        }
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
            rewriteFilenameFromMetadata: renameEnabled,
            filenameTemplate: SeratoFeatureFlags.filenameFormatTemplate()
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

    // MARK: - Bulk rename

    /// Builds the preview and asks for confirmation. Nothing is renamed until
    /// the user accepts, and the message spells out what will be skipped.
    private func prepareBulkRename(for tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // Don't rename files a background tag job is writing.
        let tracks = backgroundTagJobs.unlockedTracks(tracks)
        guard !tracks.isEmpty else {
            bulkRenameMessage = "Those tracks are being updated by a background tag job. Try again once it finishes."
            return
        }
        do {
            let preview = try TrackBulkRenameService.preview(
                tracks: tracks,
                template: SeratoFeatureFlags.filenameFormatTemplate(),
                databaseFileURL: libraryService.databaseFile
            )
            guard !preview.isEmpty else {
                bulkRenameMessage = "Nothing to rename. \(skipSummary(for: preview.skips))"
                return
            }
            pendingBulkRename = BulkRenameRequest(preview: preview)
        } catch {
            bulkRenameMessage = error.localizedDescription
        }
    }

    private func skipSummary(for skips: [TrackBulkRenameService.Skip]) -> String {
        guard !skips.isEmpty else { return "" }

        var counts: [String: Int] = [:]
        for skip in skips {
            switch skip.reason {
            case .alreadyNamedCorrectly: counts["already named correctly", default: 0] += 1
            case .noNameFromTemplate: counts["no tags to build a name from", default: 0] += 1
            case .destinationExists: counts["a file already has that name", default: 0] += 1
            case .collidesWithAnotherRename: counts["would collide with another selected track", default: 0] += 1
            case .notInDatabase: counts["not in the Serato library", default: 0] += 1
            }
        }
        let parts = counts.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }
        return "Skipping: " + parts.joined(separator: ", ") + "."
    }

    private func performBulkRename(_ preview: TrackBulkRenameService.Preview) {
        pendingBulkRename = nil

        do {
            let result = try TrackBulkRenameService.apply(preview)
            // Renaming rewrites crate files on disk, so the in-memory crates
            // would otherwise still point at the old paths.
            reloadLibrary()

            var message = "Renamed \(result.renamedCount) file\(result.renamedCount == 1 ? "" : "s")."
            if !result.skips.isEmpty {
                message += " " + skipSummary(for: result.skips)
            }
            bulkRenameMessage = message
        } catch {
            bulkRenameMessage = error.localizedDescription
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
    @State private var youTubeKeyInput = ""
    @State private var acoustIDKeyInput = ""
    @State private var anthropicKeyInput = ""
    @State private var validatingAnthropicKey = false
    @AppStorage(ClaudeAPIClient.modelDefaultsKey) private var anthropicModel = ClaudeModel.opus5.rawValue
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

                            Text("Anthropic (AI tag verification)")
                                .font(.caption.weight(.semibold))
                            Text(
                                "1. Create an Anthropic account. 2. Create an API key in the Console. "
                                + "3. Add credit to the account — AI tag verification is billed to you per track."
                            )
                            .font(.caption)
                            Link("Open the Anthropic Console API keys page", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                .font(.caption)

                            Text("YouTube (genre fallback, optional)")
                                .font(.caption.weight(.semibold))
                            Text("1. Create a Google Cloud project. 2. Enable the YouTube Data API v3. 3. Create an API key. Only used as a last resort for genre, and it spends your daily quota.")
                                .font(.caption)
                            Link("Open the Google Cloud credentials page", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
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

                    Text("YouTube Data API Key (Genre Fallback)")
                        .font(.subheadline.weight(.semibold))

                    SecureField("Paste YouTube Data API key", text: $youTubeKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Text("Optional last resort for inferring genre when the free sources come up empty. Spends your daily YouTube Data API quota, so it stays off until a key is added. Stored securely in the app's settings.")
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

                    Divider()

                    CloudModelProviderSection(
                        anthropicKeyInput: $anthropicKeyInput,
                        validatingAnthropicKey: $validatingAnthropicKey,
                        anthropicModel: $anthropicModel,
                        statusMessage: $statusMessage
                    )

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

                    Divider()

                    FilenameFormatSection()
                }
            }

            HStack {
                Button("Clear") {
                    UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.youTubeAPIKeyDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: AudioFingerprintService.tokenDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: ClaudeAPIClient.apiKeyDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: OpenAICompatibleClient.apiKeyDefaultsKey)
                    discogsTokenInput = ""
                    youTubeKeyInput = ""
                    acoustIDKeyInput = ""
                    anthropicKeyInput = ""
                    statusMessage = "API tokens cleared."
                }
                .help("Remove the saved Discogs, YouTube, AcoustID, and Anthropic API keys.")

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .help("Close without saving changes.")

                Button("Save") {
                    let discogsTrimmed = discogsTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let acoustIDTrimmed = acoustIDKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let anthropicTrimmed = anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

                    if discogsTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    } else {
                        UserDefaults.standard.set(discogsTrimmed, forKey: OnlineTrackMetadataLookupService.discogsTokenDefaultsKey)
                    }

                    let youTubeTrimmed = youTubeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if youTubeTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: OnlineTrackMetadataLookupService.youTubeAPIKeyDefaultsKey)
                    } else {
                        UserDefaults.standard.set(youTubeTrimmed, forKey: OnlineTrackMetadataLookupService.youTubeAPIKeyDefaultsKey)
                    }

                    if acoustIDTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: AudioFingerprintService.tokenDefaultsKey)
                    } else {
                        UserDefaults.standard.set(acoustIDTrimmed, forKey: AudioFingerprintService.tokenDefaultsKey)
                    }

                    if anthropicTrimmed.isEmpty {
                        UserDefaults.standard.removeObject(forKey: ClaudeAPIClient.apiKeyDefaultsKey)
                    } else {
                        UserDefaults.standard.set(anthropicTrimmed, forKey: ClaudeAPIClient.apiKeyDefaultsKey)
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
            youTubeKeyInput = UserDefaults.standard.string(forKey: OnlineTrackMetadataLookupService.youTubeAPIKeyDefaultsKey) ?? ""
            acoustIDKeyInput = UserDefaults.standard.string(forKey: AudioFingerprintService.tokenDefaultsKey) ?? ""
            anthropicKeyInput = UserDefaults.standard.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) ?? ""
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

// MARK: - Cloud Model Provider Section

/// Settings for the bring-your-own-key tier.
///
/// Two providers rather than a long list: Anthropic natively, because it is the
/// only one offering a server-side web search, and then anything speaking
/// OpenAI's `/chat/completions` shape — which covers OpenAI, OpenRouter, Groq,
/// Mistral, DeepSeek, and locally-run models under Ollama or LM Studio. A base
/// URL and a model name reach all of them, including the free local ones.
private struct CloudModelProviderSection: View {
    @Binding var anthropicKeyInput: String
    @Binding var validatingAnthropicKey: Bool
    @Binding var anthropicModel: String
    @Binding var statusMessage: String?

    @AppStorage(AITagVerificationService.providerDefaultsKey)
    private var providerRawValue = AITagVerificationService.Provider.anthropic.rawValue
    @AppStorage(OpenAICompatibleClient.baseURLDefaultsKey)
    private var baseURL = OpenAICompatibleClient.defaultBaseURL
    @AppStorage(OpenAICompatibleClient.modelDefaultsKey)
    private var compatibleModel = ""

    @State private var compatibleKeyInput = ""
    @State private var isValidatingCompatible = false

    private var provider: AITagVerificationService.Provider {
        AITagVerificationService.Provider(rawValue: providerRawValue) ?? .anthropic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cloud AI Provider (Tag Verification)")
                .font(.subheadline.weight(.semibold))

            Text(
                "Only needed for the \"Cloud AI\" verification tier. The free cross-check and the "
                + "Apple on-device tier need nothing here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $providerRawValue) {
                ForEach(AITagVerificationService.Provider.allCases, id: \.rawValue) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch provider {
            case .anthropic:
                anthropicFields
            case .openAICompatible:
                compatibleFields
            }
        }
        .onAppear {
            compatibleKeyInput = UserDefaults.standard
                .string(forKey: OpenAICompatibleClient.apiKeyDefaultsKey) ?? ""
        }
    }

    @ViewBuilder
    private var anthropicFields: some View {
        SecureField("Paste Anthropic API key", text: $anthropicKeyInput)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button(validatingAnthropicKey ? "Validating..." : "Validate Key") {
                validateAnthropicKey()
            }
            .disabled(validatingAnthropicKey)
            .help("Check that the Anthropic API key works.")

            if validatingAnthropicKey {
                ProgressView().controlSize(.small)
            }
        }

        Picker("Model", selection: $anthropicModel) {
            ForEach(ClaudeModel.allCases, id: \.rawValue) { model in
                Text(model.displayName).tag(model.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)

        Text("Anthropic is the only provider that can search the web itself, which is what makes it strongest on bootlegs and edits.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var compatibleFields: some View {
        Menu("Use a preset…") {
            ForEach(OpenAICompatibleClient.presets) { preset in
                Button(preset.name) {
                    baseURL = preset.baseURL
                    if compatibleModel.isEmpty {
                        compatibleModel = preset.exampleModel
                    }
                }
            }
        }
        .frame(maxWidth: 200, alignment: .leading)

        TextField("API base URL", text: $baseURL)
            .textFieldStyle(.roundedBorder)
        TextField("Model name (for example gpt-5)", text: $compatibleModel)
            .textFieldStyle(.roundedBorder)
        SecureField("API key (leave blank for a local model)", text: $compatibleKeyInput)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button(isValidatingCompatible ? "Validating..." : "Save & Validate") {
                saveAndValidateCompatible()
            }
            .disabled(isValidatingCompatible)
            .help("Save these settings and make one small request to check they work.")

            if isValidatingCompatible {
                ProgressView().controlSize(.small)
            }
        }

        Text(
            "Any service speaking OpenAI's chat-completions API works. A model running locally under "
            + "Ollama or LM Studio needs no key and costs nothing. These providers cannot search the "
            + "web, so they judge from the database evidence EZLibrary gathers."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func validateAnthropicKey() {
        let key = anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "Enter an Anthropic API key first."
            return
        }

        validatingAnthropicKey = true
        statusMessage = "Validating Anthropic key..."

        Task {
            do {
                _ = try await ClaudeAPIClient.validateAPIKey(key)
                await MainActor.run {
                    validatingAnthropicKey = false
                    statusMessage = "Anthropic key is valid."
                }
            } catch {
                await MainActor.run {
                    validatingAnthropicKey = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveAndValidateCompatible() {
        let trimmedKey = compatibleKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            UserDefaults.standard.removeObject(forKey: OpenAICompatibleClient.apiKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmedKey, forKey: OpenAICompatibleClient.apiKeyDefaultsKey)
        }

        guard let configuration = OpenAICompatibleClient.configuration() else {
            statusMessage = "Enter a model name, and an API key unless the model runs on this Mac."
            return
        }

        isValidatingCompatible = true
        statusMessage = "Checking \(configuration.model)..."

        Task {
            do {
                _ = try await OpenAICompatibleClient.validate(configuration: configuration)
                await MainActor.run {
                    isValidatingCompatible = false
                    statusMessage = "\(configuration.model) answered — the provider is set up."
                }
            } catch {
                await MainActor.run {
                    isValidatingCompatible = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Filename Format Section

/// Settings sub-view for configuring the bulk-rename filename format template.
private struct FilenameFormatSection: View {
    @AppStorage(SeratoFeatureFlags.filenameFormatTemplateDefaultsKey)
    private var template: String = SeratoFeatureFlags.defaultFilenameFormatTemplate

    /// A scratch copy so the user can type freely without every keystroke
    /// hitting AppStorage.
    @State private var draft: String = ""
    @State private var isEditing = false

    private let previewTrack = Track(
        seratoStoredPath: "/Music/sample.mp3",
        fileURL: URL(fileURLWithPath: "/Music/sample.mp3"),
        title: "Title (Extended)",
        artist: "Artist",
        album: "Album",
        genre: "Electronic",
        year: 2023,
        bpm: 128,
        key: "Am"
    )

    /// Returns the saved template, falling back to the default when blank.
    private var storedTemplate: String {
        template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SeratoFeatureFlags.defaultFilenameFormatTemplate
            : template
    }

    private var effectiveTemplate: String {
        isEditing ? draft : storedTemplate
    }

    private var previewStem: String {
        TrackFilenameFormatter.renderStem(for: previewTrack, template: effectiveTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Renaming Format")
                .font(.subheadline.weight(.semibold))

            Text("Template used when bulk-renaming tracks. Combine tokens and literal separators.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Token insertion buttons
            VStack(alignment: .leading, spacing: 4) {
                Text("Insert token:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                    spacing: 6
                ) {
                    ForEach(TrackFilenameFormatter.Token.allCases, id: \.self) { token in
                        Button(token.displayName) {
                            appendToken(token)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Insert \(token.rawValue) into the template")
                    }
                }
            }

            // Editable template field
            TextField("e.g. {artist}-{title}-{album}-{year}", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onAppear { draft = storedTemplate }
                .onChange(of: draft) { isEditing = true }
                .onSubmit { commitDraft() }

            HStack(spacing: 8) {
                Button("Reset to Default") {
                    draft = SeratoFeatureFlags.defaultFilenameFormatTemplate
                    commitDraft()
                }
                .controlSize(.small)
                .help("Restore the default template: \(SeratoFeatureFlags.defaultFilenameFormatTemplate)")

                Button("Apply") {
                    commitDraft()
                }
                .controlSize(.small)
                .disabled(!isEditing)
            }

            // Live preview
            if !previewStem.isEmpty {
                HStack(spacing: 4) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(previewStem).mp3")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Preview: (no output — template contains no recognised tokens)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func appendToken(_ token: TrackFilenameFormatter.Token) {
        draft = (isEditing ? draft : storedTemplate) + token.rawValue
        isEditing = true
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        template = trimmed.isEmpty ? SeratoFeatureFlags.defaultFilenameFormatTemplate : trimmed
        isEditing = false
    }
}


/// Resizable preview for a bulk rename.
///
/// A `confirmationDialog` was the obvious fit but renders at a fixed, narrow
/// alert width, which truncates exactly the part that matters — the long
/// filenames on both sides of the arrow. This lists every rename in a
/// scrollable, resizable window instead of a three-line sample.
private struct BulkRenamePreviewSheet: View {
    let preview: TrackBulkRenameService.Preview
    let template: String
    let skipSummary: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Files From Tags")
                    .font(.title2.weight(.semibold))
                Text("Using \(template) — Serato's library is updated to match, so nothing goes missing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preview.renames.enumerated()), id: \.offset) { _, rename in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rename.sourceURL.lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("→")
                                    .foregroundStyle(.secondary)
                                Text(rename.destinationURL.lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !skipSummary.isEmpty {
                Text(skipSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("\(preview.renames.count) file\(preview.renames.count == 1 ? "" : "s") to rename")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(preview.renames.count) File\(preview.renames.count == 1 ? "" : "s")") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        // Resizable: a floor so it's readable, no ceiling so long names can
        // be dragged wider.
        .frame(minWidth: 620, idealWidth: 860, maxWidth: .infinity,
               minHeight: 380, idealHeight: 560, maxHeight: .infinity)
    }
}
