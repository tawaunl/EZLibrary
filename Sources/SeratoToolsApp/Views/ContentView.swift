import SwiftUI
import AppKit
import SeratoToolsCore

enum SidebarSection: Hashable {
    case tracks
    case duplicates
    case playlistMatch
    case addMusic
    case youtubeRip
    case crates
    case tags
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

    private let sidebarWidth: CGFloat = 220
    private let middlePaneWidth: CGFloat = 320

    @EnvironmentObject private var libraryService: LibraryService
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
    @State private var selectedTracksForActions: [Track] = []
    @State private var metadataLookupTrack: Track?
    @State private var selectedTrackGenreFilter: String?
    @State private var quickTrackDeleteAction: QuickTrackDeleteAction?
    @State private var showQuickTrackDeleteConfirmation = false
    @State private var showDiscogsTokenSheet = false
    @State private var metadataSaveMessage: String?
    @State private var metadataSaveMessageTask: Task<Void, Never>?
    @State private var activeAudioTrack: Track?
    @State private var audioActivationToken = 0
    @AppStorage(Self.confirmDeleteActionsDefaultsKey) private var confirmDeleteActions = true

    private var totalCratesCount: Int {
        libraryService.crates.count
    }

    private var totalTracksInCratesCount: Int {
        Set(libraryService.crates.flatMap(\.trackPaths)).count
    }

    private var smartCratesCount: Int {
        libraryService.smartCrates.count
    }

    private var hiddenCratesCount: Int {
        Set((crateHierarchy.hiddenNodes + smartCrateHierarchy.hiddenNodes).map(\.id)).count
    }

    private var trackGenres: [String] {
        Array(Set(libraryService.tracks.map(\.genre).filter { !$0.isEmpty })).sorted()
    }

    private var filteredLibraryTracks: [Track] {
        guard let selectedTrackGenreFilter else { return libraryService.tracks }
        return libraryService.tracks.filter { $0.genre == selectedTrackGenreFilter }
    }

    private var totalTrackCount: Int {
        libraryService.tracks.count
    }

    private var totalArtistCount: Int {
        Set(libraryService.tracks.map(\.artist).filter { !$0.isEmpty }).count
    }

    private var totalGenreCount: Int {
        trackGenres.count
    }

    var body: some View {
        Group {
            VStack(spacing: 0) {
                HSplitView {
                    sidebar
                    middleContent
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }

                if let activeAudioTrack {
                    Divider()
                    HStack {
                        TrackAudioPlayerPanel(track: activeAudioTrack, activationToken: audioActivationToken)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                }
            }
        }
        .task {
            libraryPathDraft = libraryService.libraryDirectory.path
            reloadLibrary()
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
        .sheet(item: $metadataLookupTrack) { track in
            TrackMetadataEditorSheet(track: track) { metadata in
                try saveTrackMetadataEdit(track: track, metadata: metadata)
            }
        }
        .sheet(isPresented: $showDiscogsTokenSheet) {
            DiscogsTokenSettingsSheet()
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

    private func tracksLoadStatus() -> (text: String, color: Color) {
        if let loadErrorMessage = loadErrorMessage {
            return ("Library load failed: \(loadErrorMessage)", .red)
        }

        if libraryService.tracks.isEmpty {
            return ("No tracks loaded", .secondary)
        }

        return (
            "Loaded \(libraryService.tracks.count) tracks, \(libraryService.crates.count) crates, \(libraryService.smartCrates.count) smart crates",
            .secondary
        )
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Label("Tracks", systemImage: "music.note.list").tag(SidebarSection.tracks)
            Label("Duplicates", systemImage: "rectangle.on.rectangle").tag(SidebarSection.duplicates)
            Label("PlaylistMatch", systemImage: "music.quarternote.3").tag(SidebarSection.playlistMatch)
            Label("Add Music", systemImage: "plus.square.on.square").tag(SidebarSection.addMusic)
            Label("YouTube Rip", systemImage: "arrow.down.circle").tag(SidebarSection.youtubeRip)
            Label("Crates", systemImage: "square.stack").tag(SidebarSection.crates)
            Label("Tags", systemImage: "tag").tag(SidebarSection.tags)
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
                    FinderFolderControls(
                        label: "Library directory",
                        path: $libraryPathDraft,
                        browsePrompt: "Use Library",
                        browseStartURL: URL(fileURLWithPath: libraryPathDraft.isEmpty ? libraryService.libraryDirectory.path : libraryPathDraft),
                        allowsNewFolderCreation: false,
                        onPathChanged: applyLibraryDirectory
                    )
                    Button("Apply") { applyLibraryDirectory() }
                    Button("Reload") { reloadLibrary() }
                    Button("API Keys…") { showDiscogsTokenSheet = true }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Text("Using: \(libraryService.libraryDirectory.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                SectionHeaderCard(
                    title: "Tracks",
                    description: "Browse every track in the library, filter by genre, and manage metadata or deletion actions from one place.",
                    icon: "music.note.list"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(tracksLoadStatus().text)
                        .font(.callout)
                        .foregroundStyle(tracksLoadStatus().color)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            crateStatTag(title: "Tracks", value: totalTrackCount, isActive: selectedTrackGenreFilter == nil) {
                                selectedTrackGenreFilter = nil
                            }
                            crateStatTag(title: "Artists", value: totalArtistCount)
                            crateStatTag(title: "Genres", value: totalGenreCount)
                            Spacer(minLength: 0)
                        }

                        if !trackGenres.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Button("All") {
                                        selectedTrackGenreFilter = nil
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(selectedTrackGenreFilter == nil ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
                                    )
                                    .overlay(
                                        Capsule().stroke(selectedTrackGenreFilter == nil ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                                    )
                                    .foregroundStyle(selectedTrackGenreFilter == nil ? .white : .primary)

                                    ForEach(trackGenres, id: \.self) { genre in
                                        Button(genre) {
                                            selectedTrackGenreFilter = selectedTrackGenreFilter == genre ? nil : genre
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule().fill(selectedTrackGenreFilter == genre ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
                                        )
                                        .overlay(
                                            Capsule().stroke(selectedTrackGenreFilter == genre ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                                        )
                                        .foregroundStyle(selectedTrackGenreFilter == genre ? .white : .primary)
                                    }
                                }
                                .padding(.horizontal, 8)
                            }
                        }

                        HStack {
                            Button("Lookup ID3 Online") {
                                metadataLookupTrack = selectedTracksForActions.first
                            }
                            .disabled(selectedTracksForActions.count != 1)

                            Button("Delete From Library") {
                                pendingTrackDeleteSelection = selectedTracksForActions
                                performOrConfirmQuickTrackDelete(.fromLibrary)
                            }
                            .disabled(selectedTracksForActions.isEmpty)

                            Button("Delete From Computer") {
                                pendingTrackDeleteSelection = selectedTracksForActions
                                performOrConfirmQuickTrackDelete(.fromComputer)
                            }
                            .disabled(selectedTracksForActions.isEmpty)

                            Toggle("Confirm Deletes", isOn: $confirmDeleteActions)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("When off, top delete buttons execute immediately.")
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    .glowCardStyle(radius: 8, opacity: 0.05)

                    TrackTableView(
                        tracks: filteredLibraryTracks,
                        numberingMode: .listOrder,
                        onDeleteRequested: { selected in
                            pendingTrackDeleteSelection = selected
                            showTrackDeleteDialog = true
                        },
                        onMetadataEditRequested: { track, metadata in
                            applyTrackMetadataEdit(track: track, metadata: metadata)
                        },
                        onSelectionChanged: { selected in
                            selectedTracksForActions = selected
                        },
                        onTrackActivated: { track in
                            activeAudioTrack = track
                            audioActivationToken += 1
                        }
                    )
                }
            }
        case .duplicates:
            DuplicateTracksView(onLibraryChanged: reloadLibrary)
        case .playlistMatch:
            PlaylistMatchView(onLibraryChanged: reloadLibrary)
        case .addMusic:
            AddMusicView(onLibraryChanged: reloadLibrary)
        case .youtubeRip:
            YouTubeRipView(onLibraryChanged: reloadLibrary)
        case .tags:
            TagsBulkEditView(
                onApplyMetadata: { track, metadata in
                    try saveTrackMetadataEdit(track: track, metadata: metadata)
                },
                onApplyMetadataBatch: { updates in
                    try saveTrackMetadataEditsBatch(updates)
                }
            )
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
                                onTrackActivated: { track in
                                    activeAudioTrack = track
                                    audioActivationToken += 1
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

    private func reloadLibrary() {
        let previousSelectedNodeID = selectedCrateNode?.id

        do {
            try libraryService.reload()
            loadErrorMessage = nil
            crateHierarchy.rebuild(from: libraryService.crates)
            smartCrateHierarchy.rebuild(from: libraryService.smartCrates)
            selectedCrateNode = refreshedSelectedCrateNode(previousID: previousSelectedNodeID)
        } catch {
            loadErrorMessage = error.localizedDescription
            crateHierarchy.rebuild(from: [])
            smartCrateHierarchy.rebuild(from: [])
            selectedCrateNode = nil
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
        selectedTrackGenreFilter = nil
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

    private func applyTrackMetadataEdit(track: Track, metadata: SeratoTrackMetadataUpdate) {
        do {
            try saveTrackMetadataEdit(track: track, metadata: metadata)
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
    }

    private func saveTrackMetadataEdit(track: Track, metadata: SeratoTrackMetadataUpdate) throws {
        try SeratoTrackMetadataEditor.update(
            track: track,
            metadata: metadata,
            databaseFileURL: libraryService.databaseFile,
            rewriteFilenameFromMetadata: SeratoFeatureFlags.isAutoRenameFromMetadataEnabled()
        )
        try libraryService.reloadTracksOnly()
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

        var successCount = 0
        var failedNames: [String] = []

        for (track, metadata) in updates {
            do {
                try SeratoTrackMetadataEditor.update(
                    track: track,
                    metadata: metadata,
                    databaseFileURL: libraryService.databaseFile,
                    rewriteFilenameFromMetadata: SeratoFeatureFlags.isAutoRenameFromMetadataEnabled()
                )
                successCount += 1
            } catch {
                failedNames.append(track.fileURL.lastPathComponent)
            }
        }

        try libraryService.reloadTracksOnly()

        guard failedNames.isEmpty else {
            throw BulkMetadataUpdateError(successCount: successCount, failedNames: failedNames)
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

private struct DiscogsTokenSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var discogsTokenInput = ""
    @State private var acoustIDKeyInput = ""
    @State private var statusMessage: String?
    @State private var validatingAcoustIDKey = false
    @State private var showHelp = false
    @AppStorage(SeratoFeatureFlags.autoRenameFromMetadataDefaultsKey) private var autoRenameFromMetadata = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

                    Text("Used for Discogs metadata lookup. Stored in UserDefaults as SeratoToolsDiscogsToken.")
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

                        if validatingAcoustIDKey {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Used for external audio fingerprint recognition. Must be an AcoustID application client key from acoustid.org/new-application. Stored in UserDefaults as SeratoToolsAcoustIDKey.")
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

                    Text("When saving ID3/track metadata, rename files as title-artist-album-year and update Serato database/crate paths.")
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

                Spacer()

                Button("Close") {
                    dismiss()
                }

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
            defaults.set(true, forKey: SeratoFeatureFlags.autoRenameFromMetadataDefaultsKey)
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
