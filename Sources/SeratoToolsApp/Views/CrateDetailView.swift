import SwiftUI
import SeratoToolsCore

struct CrateDetailView: View {
    private enum QuickDeleteAction {
        case fromCrate
        case fromLibrary
        case fromComputer

        var title: String {
            switch self {
            case .fromCrate:
                return "Delete From Crate"
            case .fromLibrary:
                return "Delete From Library"
            case .fromComputer:
                return "Delete From Computer"
            }
        }
    }

    private static let confirmDeleteActionsDefaultsKey = "SeratoToolsConfirmTrackDeleteActions"

    let node: CrateNode
    let filterMode: CrateListFilterMode
    let onCratesChanged: () -> Void
    let onTrackActivated: ((Track) -> Void)?
    @EnvironmentObject private var libraryService: LibraryService

    @State private var isManagingTracks = false
    @State private var trackEditErrorMessage: String?
    @State private var pendingDeleteTracks: [Track] = []
    @State private var pendingDeleteCrate: Crate?
    @State private var showTrackDeleteDialog = false
    @State private var selectedTracksForActions: [Track] = []
    @State private var metadataLookupTrack: Track?
    @State private var quickDeleteAction: QuickDeleteAction?
    @State private var showQuickDeleteConfirmation = false
    @State private var metadataSaveMessage: String?
    @State private var metadataSaveMessageTask: Task<Void, Never>?
    @AppStorage(Self.confirmDeleteActionsDefaultsKey) private var confirmDeleteActions = true
    @State private var selectedGenreFilter: String?

    var body: some View {
        Group {
            let trackPaths = effectiveTrackPaths(for: node)
            if let crate = node.crate ?? synthesizedCrateForAggregate(node: node, trackPaths: trackPaths), !trackPaths.isEmpty {
                let resolver = TrackPathResolver(tracks: libraryService.tracks)
                let resolved = trackPaths.map { path in
                    (path: path, track: resolver.resolve(path: path))
                }
                let matchedTracks = resolved.compactMap(\.track)
                let unmatchedPaths = resolved.compactMap { $0.track == nil ? $0.path : nil }
                let isEditableCrate = crate.fileURL?.pathExtension.lowercased() == "crate"
                let genreTags = Array(Set(matchedTracks.map(\.genre).filter { !$0.isEmpty })).sorted()
                let filteredMatchedTracks = selectedGenreFilter.map { genre in
                    matchedTracks.filter { $0.genre == genre }
                } ?? matchedTracks

                VStack(alignment: .leading, spacing: 0) {
                    if isEditableCrate {
                        HStack {
                            Button("Manage Tracks") {
                                isManagingTracks = true
                            }
                            Button("Lookup ID3 Online") {
                                metadataLookupTrack = selectedTracksForActions.first
                            }
                            .disabled(selectedTracksForActions.count != 1)

                            Button("Delete From Crate") {
                                pendingDeleteTracks = selectedTracksForActions
                                pendingDeleteCrate = crate
                                performOrConfirmQuickDelete(.fromCrate)
                            }
                            .disabled(selectedTracksForActions.isEmpty)

                            Button("Delete From Library") {
                                pendingDeleteTracks = selectedTracksForActions
                                pendingDeleteCrate = crate
                                performOrConfirmQuickDelete(.fromLibrary)
                            }
                            .disabled(selectedTracksForActions.isEmpty)

                            Button("Delete From Computer") {
                                pendingDeleteTracks = selectedTracksForActions
                                pendingDeleteCrate = crate
                                performOrConfirmQuickDelete(.fromComputer)
                            }
                            .disabled(selectedTracksForActions.isEmpty)

                            Toggle("Confirm Deletes", isOn: $confirmDeleteActions)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("When off, top delete buttons execute immediately.")
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }

                    if genreTags.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                statTag(title: "Tracks", value: matchedTracks.count, isActive: selectedGenreFilter == nil) {
                                    selectedGenreFilter = nil
                                }
                                statTag(title: "Artists", value: Set(matchedTracks.map(\.artist).filter { !$0.isEmpty }).count)
                                statTag(title: "Genres", value: genreTags.count)
                                Spacer(minLength: 0)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    genreTag("All", isActive: selectedGenreFilter == nil) {
                                        selectedGenreFilter = nil
                                    }
                                    ForEach(genreTags, id: \.self) { genre in
                                        genreTag(genre, isActive: selectedGenreFilter == genre) {
                                            selectedGenreFilter = selectedGenreFilter == genre ? nil : genre
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }

                    TrackTableView(
                        tracks: filteredMatchedTracks,
                        numberingMode: .listOrder,
                        onDeleteRequested: { selected in
                            pendingDeleteTracks = selected
                            pendingDeleteCrate = crate
                            showTrackDeleteDialog = true
                        },
                        onMetadataEditRequested: { track, metadata in
                            applyTrackMetadataEdit(track: track, metadata: metadata)
                        },
                        onSelectionChanged: { selected in
                            selectedTracksForActions = selected
                        },
                        onTrackActivated: { track in
                            onTrackActivated?(track)
                        }
                    )

                    // Confirmed to happen legitimately for some Smart Crate
                    // entries referencing a different Serato profile/volume
                    // context — shown separately rather than as an error.
                    if !unmatchedPaths.isEmpty {
                        Divider()
                        DisclosureGroup("Not in local library (\(unmatchedPaths.count))") {
                            ForEach(unmatchedPaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "folder",
                    description: Text("This groups nested crates — select one of its children to see tracks.")
                )
            }
        }
        .sheet(isPresented: $isManagingTracks) {
            if let crate = node.crate {
                CrateTrackManagerView(crate: crate, libraryTracks: libraryService.tracks) {
                    onCratesChanged()
                }
            }
        }
        .sheet(item: $metadataLookupTrack) { track in
            TrackMetadataEditorSheet(track: track) { metadata in
                try saveTrackMetadataEdit(track: track, metadata: metadata)
            }
        }
        .onChange(of: node.id) {
            selectedGenreFilter = nil
        }
        .onDisappear {
            selectedGenreFilter = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            selectedGenreFilter = nil
        }
        .alert(
            "Couldn't Update Crate",
            isPresented: Binding(get: { trackEditErrorMessage != nil }, set: { if !$0 { trackEditErrorMessage = nil } })
        ) {
            Button("OK") { trackEditErrorMessage = nil }
        } message: {
            Text(trackEditErrorMessage ?? "")
        }
        .confirmationDialog(
            "Delete Selected Tracks",
            isPresented: $showTrackDeleteDialog,
            titleVisibility: .visible
        ) {
            if let pendingDeleteCrate, pendingDeleteCrate.fileURL?.pathExtension.lowercased() == "crate" {
                Button("Delete From Crate", role: .destructive) {
                    deleteSelectedTracksFromCrate()
                }
            }
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
            Text("Choose how to delete \(pendingDeleteTracks.count) selected track\(pendingDeleteTracks.count == 1 ? "" : "s").")
        }
        .confirmationDialog(
            "Confirm Delete",
            isPresented: $showQuickDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let action = quickDeleteAction {
                Button(action.title, role: .destructive) {
                    executeQuickDelete(action)
                }
            }
            Button("Turn Off Confirmations") {
                confirmDeleteActions = false
                if let action = quickDeleteAction {
                    executeQuickDelete(action)
                }
            }
            Button("Cancel", role: .cancel) {
                quickDeleteAction = nil
            }
        } message: {
            if let action = quickDeleteAction {
                Text("\(action.title) for \(pendingDeleteTracks.count) selected track\(pendingDeleteTracks.count == 1 ? "" : "s")?")
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

    private func performOrConfirmQuickDelete(_ action: QuickDeleteAction) {
        guard !pendingDeleteTracks.isEmpty else { return }
        if confirmDeleteActions {
            quickDeleteAction = action
            showQuickDeleteConfirmation = true
        } else {
            executeQuickDelete(action)
        }
    }

    private func executeQuickDelete(_ action: QuickDeleteAction) {
        quickDeleteAction = nil
        switch action {
        case .fromCrate:
            deleteSelectedTracksFromCrate()
        case .fromLibrary:
            deleteSelectedTracksFromLibrary()
        case .fromComputer:
            deleteSelectedTracksFromComputer()
        }
    }

    private func clearPendingTrackDelete() {
        pendingDeleteTracks = []
        pendingDeleteCrate = nil
    }

    private func deleteSelectedTracksFromCrate() {
        guard let crate = pendingDeleteCrate,
              crate.fileURL?.pathExtension.lowercased() == "crate" else {
            clearPendingTrackDelete()
            return
        }

        do {
            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            let rewritten = crate.trackPaths.filter { !removedPaths.contains($0) }
            _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: rewritten)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedTracksFromLibrary() {
        do {
            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedTracksFromComputer() {
        do {
            for track in pendingDeleteTracks {
                guard FileManager.default.fileExists(atPath: track.fileURL.path) else { continue }
                _ = try FileManager.default.trashItem(at: track.fileURL, resultingItemURL: nil)
            }

            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
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
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func saveTrackMetadataEdit(track: Track, metadata: SeratoTrackMetadataUpdate) throws {
        try SeratoTrackMetadataEditor.update(
            track: track,
            metadata: metadata,
            databaseFileURL: libraryService.databaseFile,
            rewriteFilenameFromMetadata: SeratoFeatureFlags.isAutoRenameFromMetadataEnabled()
        )
        onCratesChanged()
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

    private func statTag(title: String, value: Int, isActive: Bool = false, action: (() -> Void)? = nil) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? .white.opacity(0.92) : .secondary)
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isActive ? .white : .primary)
        }
        .padding(.horizontal, 12)
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
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private func genreTag(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    Capsule().stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func effectiveTrackPaths(for node: CrateNode) -> [String] {
        if let crate = node.crate {
            return crate.trackPaths
        }

        let pathPrefix = node.pathComponents
        let sourceCrates: [Crate]
        switch filterMode {
        case .smartOnly:
            sourceCrates = libraryService.smartCrates
        case .all, .hiddenOnly:
            sourceCrates = libraryService.crates + libraryService.smartCrates
        }

        let descendantCrates = sourceCrates
            .filter { $0.pathComponents.starts(with: pathPrefix) }

        var seen = Set<String>()
        var merged: [String] = []
        for crate in descendantCrates {
            for path in crate.trackPaths where seen.insert(path).inserted {
                merged.append(path)
            }
        }
        return merged
    }

    private func synthesizedCrateForAggregate(node: CrateNode, trackPaths: [String]) -> Crate? {
        guard !trackPaths.isEmpty else { return nil }
        return Crate(pathComponents: node.pathComponents, trackPaths: trackPaths, fileURL: nil)
    }
}

private struct TrackPathResolver {
    private let exactByNormalizedPath: [String: Track]
    private let byFilename: [String: [Track]]

    init(tracks: [Track]) {
        exactByNormalizedPath = Dictionary(
            tracks.map { (Self.normalize(path: $0.seratoStoredPath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        byFilename = Dictionary(grouping: tracks, by: {
            $0.fileURL.lastPathComponent.lowercased()
        })
    }

    func resolve(path: String) -> Track? {
        let normalized = Self.normalize(path: path)
        if let exact = exactByNormalizedPath[normalized] {
            return exact
        }

        // Smart crates can reference legacy profile-specific absolute-like
        // paths (e.g. Users/.../All Music/track.mp3) that no longer match
        // current `database V2` stored paths. Fall back to filename only
        // when it maps to a unique library track to avoid wrong matches.
        let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard let candidates = byFilename[filename], candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    private static func normalize(path: String) -> String {
        path
            .replacingOccurrences(of: "\\\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct CrateTrackManagerView: View {
    @Environment(\.dismiss) private var dismiss

    let crate: Crate
    let libraryTracks: [Track]
    let onSaved: () -> Void

    @State private var searchText = ""
    @State private var workingPaths: [String]
    @State private var saveErrorMessage: String?

    init(crate: Crate, libraryTracks: [Track], onSaved: @escaping () -> Void) {
        self.crate = crate
        self.libraryTracks = libraryTracks
        self.onSaved = onSaved
        _workingPaths = State(initialValue: crate.trackPaths)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Manage Tracks: \(crate.name)")
                    .font(.headline)
                Spacer()
            }

            TextField("Search library tracks", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredTracks, id: \.id) { track in
                HStack {
                    VStack(alignment: .leading) {
                        Text(track.title.isEmpty ? track.fileURL.lastPathComponent : track.title)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isIncluded(track.seratoStoredPath) ? "Remove" : "Add") {
                        toggle(track.seratoStoredPath)
                    }
                }
            }

            HStack {
                Text("\(workingPaths.count) track\(workingPaths.count == 1 ? "" : "s") in crate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .alert(
            "Couldn't Save Crate",
            isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })
        ) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var filteredTracks: [Track] {
        if searchText.isEmpty {
            return libraryTracks
        }
        return libraryTracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.artist.localizedCaseInsensitiveContains(searchText)
            || $0.album.localizedCaseInsensitiveContains(searchText)
            || $0.fileURL.lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isIncluded(_ path: String) -> Bool {
        workingPaths.contains(path)
    }

    private func toggle(_ path: String) {
        if let index = workingPaths.firstIndex(of: path) {
            workingPaths.remove(at: index)
        } else {
            workingPaths.append(path)
        }
    }

    private func save() {
        do {
            _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: workingPaths)
            onSaved()
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
