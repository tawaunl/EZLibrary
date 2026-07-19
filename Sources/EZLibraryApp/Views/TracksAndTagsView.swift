import SwiftUI
import EZLibraryCore

struct TracksAndTagsView: View {
    private enum CompletionTrend {
        case aboveBaseline
        case belowBaseline
        case equal

        var symbol: String {
            switch self {
            case .aboveBaseline:
                return "▲"
            case .belowBaseline:
                return "▼"
            case .equal:
                return "●"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .aboveBaseline:
                return "Above global baseline"
            case .belowBaseline:
                return "Below global baseline"
            case .equal:
                return "Equal to global baseline"
            }
        }

        var valueColor: Color {
            switch self {
            case .aboveBaseline:
                return .green
            case .belowBaseline:
                return .red
            case .equal:
                return .primary
            }
        }
    }

    private static let allTracksID = "all_tracks"

    private enum FillField: Hashable {
        case artist
        case album
        case genre
        case year
    }

    @EnvironmentObject private var libraryService: LibraryService

    let onApplyMetadata: (Track, SeratoTrackMetadataUpdate) throws -> Void
    let onApplyMetadataBatch: (([(Track, SeratoTrackMetadataUpdate)]) throws -> Void)?
    let onTrackActivated: ((Track, [Track]) -> Void)?
    let onDeleteRequested: ([Track]) -> Void
    let onDeleteFromLibrary: ([Track]) -> Void
    let onDeleteFromComputer: ([Track]) -> Void

    @AppStorage("SeratoToolsConfirmTrackDeleteActions") private var confirmDeleteActions = true
    @State private var selectedScopeID: String = Self.allTracksID
    @State private var selectedTracks: [Track] = []
    @State private var metadataLookupTrack: Track?
    @State private var searchText = ""
    @State private var selectedGenreFilter: String?
    @State private var fillFilter: FillField?
    @State private var bulkArtist = ""
    @State private var bulkAlbum = ""
    @State private var bulkGenre = ""
    @State private var bulkYear = ""
    @State private var onlyFillEmpty = true
    @State private var isBulkLookupRunning = false
    @State private var bulkLookupMessage: String?
    @State private var operationErrorMessage: String?
    @State private var pendingTopHitUpdates: [(Track, SeratoTrackMetadataUpdate)] = []
    @State private var showTopHitConfirmation = false

    private var regularTree: [CrateNode] {
        CrateHierarchy.build(from: libraryService.crates)
    }

    private var smartTree: [CrateNode] {
        CrateHierarchy.build(from: libraryService.smartCrates)
    }

    private var combinedTree: [CrateNode] {
        mergedTrees(regularTree, smartTree)
    }

    private var allNodesByID: [String: CrateNode] {
        var map: [String: CrateNode] = [:]
        flatten(combinedTree, into: &map)
        return map
    }

    private var smartNodeIDs: Set<String> {
        var map: [String: CrateNode] = [:]
        flatten(smartTree, into: &map)
        return Set(map.keys)
    }

    private var selectedNode: CrateNode? {
        allNodesByID[selectedScopeID]
    }

    private var selectedScopeTitle: String {
        if selectedScopeID == Self.allTracksID {
            return "All Tracks"
        }
        return selectedNode?.pathComponents.joined(separator: " / ") ?? "All Tracks"
    }

    private var scopeTracks: [Track] {
        guard let selectedNode else {
            return filteredTracks(from: libraryService.tracks)
        }

        let resolver = TrackPathResolver(tracks: libraryService.tracks)
        let selectedPaths = effectiveTrackPaths(for: selectedNode)
        let tracks = selectedPaths.compactMap { resolver.resolve(path: $0) }
        return filteredTracks(from: tracks)
    }

    private var scopeGenres: [String] {
        let genres = scopeTracks
            .map { $0.genre.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(genres)).sorted()
    }

    private var scopeGenreTracks: [Track] {
        guard let selectedGenreFilter else { return scopeTracks }
        return scopeTracks.filter { $0.genre == selectedGenreFilter }
    }

    private var displayedTracks: [Track] {
        guard let fillFilter else { return scopeGenreTracks }
        return scopeGenreTracks.filter { !isFilled(fillFilter, $0) }
    }

    private var filteredTree: [CrateNode] {
        filterTree(combinedTree)
    }

    private var artistFilledCount: Int {
        scopeGenreTracks.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var albumFilledCount: Int {
        scopeGenreTracks.filter { !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var genreFilledCount: Int {
        scopeGenreTracks.filter { !$0.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var yearFilledCount: Int {
        scopeGenreTracks.filter { $0.year != nil }.count
    }

    private var globalArtistFilledCount: Int {
        libraryService.tracks.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var globalAlbumFilledCount: Int {
        libraryService.tracks.filter { !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var globalGenreFilledCount: Int {
        libraryService.tracks.filter { !$0.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var globalYearFilledCount: Int {
        libraryService.tracks.filter { $0.year != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeaderCard(
                title: "Tracks & Tags",
                description: "Browse every track, pick a crate scope, and bulk-fill missing artist, album, genre, and year metadata, then apply lookup results or delete tracks track by track.",
                icon: "music.note.list"
            )

            HSplitView {
                crateListPane
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)

                VStack(alignment: .leading, spacing: 10) {
                    statsHeader
                    genreFilterBar
                    bulkEditor
                    selectionStatusBar

                    TrackTableView(
                        tracks: displayedTracks,
                        numberingMode: .listOrder,
                        onDeleteRequested: { selected in
                            onDeleteRequested(selected)
                        },
                        onMetadataEditRequested: { track, metadata in
                            do {
                                try onApplyMetadata(track, metadata)
                            } catch {
                                operationErrorMessage = error.localizedDescription
                            }
                        },
                        onSelectionChanged: { selected in
                            selectedTracks = selected
                        },
                        onTrackActivated: { track, list in
                            onTrackActivated?(track, list)
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedScopeID != Self.allTracksID, allNodesByID[selectedScopeID] == nil {
                selectedScopeID = Self.allTracksID
            }
        }
        .onChange(of: selectedScopeID) {
            selectedGenreFilter = nil
            fillFilter = nil
        }
        .onChange(of: selectedGenreFilter) {
            fillFilter = nil
        }
        .onChange(of: searchText) {
            if let selectedGenreFilter, !scopeGenres.contains(selectedGenreFilter) {
                self.selectedGenreFilter = nil
            }
        }
        .alert(
            "Couldn't Update Tags",
            isPresented: Binding(get: { operationErrorMessage != nil }, set: { if !$0 { operationErrorMessage = nil } })
        ) {
            Button("OK") { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "")
        }
        .sheet(item: $metadataLookupTrack) { track in
            TrackMetadataEditorSheet(track: track) { metadata in
                try onApplyMetadata(track, metadata)
            }
        }
        .confirmationDialog(
            "Apply Top-Hit Metadata",
            isPresented: $showTopHitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply to \(pendingTopHitUpdates.count) Track\(pendingTopHitUpdates.count == 1 ? "" : "s")") {
                applyPendingTopHitUpdates()
            }
            Button("Cancel", role: .cancel) {
                pendingTopHitUpdates = []
            }
        } message: {
            Text("Top search-hit metadata will be applied for Artist, Album, Genre, and Year on \(pendingTopHitUpdates.count) selected track\(pendingTopHitUpdates.count == 1 ? "" : "s").")
        }
    }

    private var crateListPane: some View {
        VStack(spacing: 8) {
            TextField("Search tracks & scope", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            List(selection: $selectedScopeID) {
                Text("All Tracks")
                    .tag(Self.allTracksID)

                OutlineGroup(filteredTree, children: \.outlineChildren) { node in
                    HStack(spacing: 6) {
                        Text(node.name)
                        if smartNodeIDs.contains(node.id) {
                            Text("Smart")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(node.id)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var statsHeader: some View {
        let total = scopeGenreTracks.count
        let scopeArtistPercent = percentValue(filled: artistFilledCount, total: total)
        let scopeAlbumPercent = percentValue(filled: albumFilledCount, total: total)
        let scopeGenrePercent = percentValue(filled: genreFilledCount, total: total)
        let scopeYearPercent = percentValue(filled: yearFilledCount, total: total)
        let globalArtistPercent = percentValue(filled: globalArtistFilledCount, total: libraryService.tracks.count)
        let globalAlbumPercent = percentValue(filled: globalAlbumFilledCount, total: libraryService.tracks.count)
        let globalGenrePercent = percentValue(filled: globalGenreFilledCount, total: libraryService.tracks.count)
        let globalYearPercent = percentValue(filled: globalYearFilledCount, total: libraryService.tracks.count)

        return HStack(spacing: 10) {
            statTag(
                title: "Tracks",
                valueText: "\(total)",
                subtitle: fillFilter == nil ? selectedScopeTitle : "\(displayedTracks.count) shown • tap to clear",
                action: { fillFilter = nil }
            )
            statTag(
                title: "Artist Filled",
                valueText: percentText(filled: artistFilledCount, total: total),
                subtitle: fillSubtitle(field: .artist, filled: artistFilledCount, total: total),
                baseline: baselineText(globalPercent: globalArtistPercent, scopePercent: scopeArtistPercent),
                trend: trend(scopePercent: scopeArtistPercent, globalPercent: globalArtistPercent),
                isActive: fillFilter == .artist,
                action: { toggleFillFilter(.artist) }
            )
            statTag(
                title: "Album Filled",
                valueText: percentText(filled: albumFilledCount, total: total),
                subtitle: fillSubtitle(field: .album, filled: albumFilledCount, total: total),
                baseline: baselineText(globalPercent: globalAlbumPercent, scopePercent: scopeAlbumPercent),
                trend: trend(scopePercent: scopeAlbumPercent, globalPercent: globalAlbumPercent),
                isActive: fillFilter == .album,
                action: { toggleFillFilter(.album) }
            )
            statTag(
                title: "Genre Filled",
                valueText: percentText(filled: genreFilledCount, total: total),
                subtitle: fillSubtitle(field: .genre, filled: genreFilledCount, total: total),
                baseline: baselineText(globalPercent: globalGenrePercent, scopePercent: scopeGenrePercent),
                trend: trend(scopePercent: scopeGenrePercent, globalPercent: globalGenrePercent),
                isActive: fillFilter == .genre,
                action: { toggleFillFilter(.genre) }
            )
            statTag(
                title: "Year Filled",
                valueText: percentText(filled: yearFilledCount, total: total),
                subtitle: fillSubtitle(field: .year, filled: yearFilledCount, total: total),
                baseline: baselineText(globalPercent: globalYearPercent, scopePercent: scopeYearPercent),
                trend: trend(scopePercent: scopeYearPercent, globalPercent: globalYearPercent),
                isActive: fillFilter == .year,
                action: { toggleFillFilter(.year) }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    @ViewBuilder
    private var genreFilterBar: some View {
        if !scopeGenres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    genreFilterButton(title: "All", isActive: selectedGenreFilter == nil) {
                        selectedGenreFilter = nil
                    }

                    ForEach(scopeGenres, id: \.self) { genre in
                        genreFilterButton(title: genre, isActive: selectedGenreFilter == genre) {
                            selectedGenreFilter = selectedGenreFilter == genre ? nil : genre
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .glowCardStyle(radius: 8, opacity: 0.05)
        }
    }

    private func genreFilterButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
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

    private var bulkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Bulk Tag Edit")
                    .font(.headline)
                Text("(Selected: \(selectedTracks.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Lookup ID3 Online") {
                    metadataLookupTrack = selectedTracks.first
                }
                .disabled(selectedTracks.count != 1)
                .help("Search online sources for metadata for the selected track. Select exactly one track.")
                Button("Fill Missing Genre/Year") {
                    lookupMissingGenreAndYear()
                }
                .disabled(selectedTracks.isEmpty || isBulkLookupRunning)
                .help("Look up genre and year online and fill them in for the selected tracks.")
                Button("Apply Top Hit (A/Al/G/Y)") {
                    applyTopHitMetadataToSelected()
                }
                .disabled(selectedTracks.isEmpty || isBulkLookupRunning)
                .help("Apply the best online match's Artist, Album, Genre, and Year to the selected tracks.")
                if isBulkLookupRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Toggle("Only Fill Empty", isOn: $onlyFillEmpty)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Delete From Library") {
                    onDeleteFromLibrary(selectedTracks)
                }
                .disabled(selectedTracks.isEmpty)
                .help("Remove the selected tracks from the Serato library. Files stay on disk.")

                Button("Delete From Computer") {
                    onDeleteFromComputer(selectedTracks)
                }
                .disabled(selectedTracks.isEmpty)
                .help("Remove the selected tracks from the library and move their files to the Trash.")

                Toggle("Confirm Deletes", isOn: $confirmDeleteActions)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("When off, the delete buttons execute immediately.")
                Spacer(minLength: 0)
            }

            if let bulkLookupMessage {
                Text(bulkLookupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Artist", text: $bulkArtist)
                    .textFieldStyle(.roundedBorder)
                TextField("Album", text: $bulkAlbum)
                    .textFieldStyle(.roundedBorder)
                TextField("Genre", text: $bulkGenre)
                    .textFieldStyle(.roundedBorder)
                TextField("Year", text: $bulkYear)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button("Apply To Selected") {
                    applyBulkMetadata()
                }
                .disabled(selectedTracks.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var selectionStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(selectedTracks.isEmpty ? Color.secondary : Color.green)
                .font(.caption)

            Text(selectedTracks.isEmpty
                ? "No tracks selected"
                : "\(selectedTracks.count) track\(selectedTracks.count == 1 ? "" : "s") selected")
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            Spacer(minLength: 0)

            Text(selectedScopeTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    selectedTracks.isEmpty ? Color.secondary.opacity(0.2) : Color.green.opacity(0.45),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 10)
    }

    private func applyBulkMetadata() {
        bulkLookupMessage = nil
        let artistInput = bulkArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumInput = bulkAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        let genreInput = bulkGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearInput = bulkYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearValue = yearInput.isEmpty ? nil : Int(yearInput)

        if !yearInput.isEmpty && yearValue == nil {
            operationErrorMessage = "Year must be a valid number."
            return
        }

        guard !artistInput.isEmpty || !albumInput.isEmpty || !genreInput.isEmpty || yearValue != nil else {
            operationErrorMessage = "Enter at least one value (Artist, Album, Genre, or Year) before applying."
            return
        }

        var updates: [(Track, SeratoTrackMetadataUpdate)] = []

        for track in selectedTracks {
            var metadata = SeratoTrackMetadataUpdate(
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                comment: track.comment,
                key: track.key ?? "",
                bpm: track.bpm,
                year: track.year
            )

            if !artistInput.isEmpty && (!onlyFillEmpty || track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                metadata.artist = artistInput
            }
            if !albumInput.isEmpty && (!onlyFillEmpty || track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                metadata.album = albumInput
            }
            if !genreInput.isEmpty && (!onlyFillEmpty || track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                metadata.genre = genreInput
            }
            if let yearValue, (!onlyFillEmpty || track.year == nil) {
                metadata.year = yearValue
            }

            guard metadata.artist != track.artist
                || metadata.album != track.album
                || metadata.genre != track.genre
                || metadata.year != track.year
            else {
                continue
            }

            updates.append((track, metadata))
        }

        guard !updates.isEmpty else {
            bulkLookupMessage = onlyFillEmpty
                ? "No changes: the selected tracks already have those fields. Turn off \u{201C}Only Fill Empty\u{201D} to overwrite them."
                : "No changes were needed for the selected tracks."
            return
        }

        do {
            if let onApplyMetadataBatch {
                try onApplyMetadataBatch(updates)
            } else {
                for (track, metadata) in updates {
                    try onApplyMetadata(track, metadata)
                }
            }
        } catch {
            operationErrorMessage = error.localizedDescription
            return
        }

        let updatedCount = updates.count
        bulkLookupMessage = "Applied changes to \(updatedCount) track\(updatedCount == 1 ? "" : "s")."
    }

    private func lookupMissingGenreAndYear() {
        guard !selectedTracks.isEmpty else { return }

        bulkLookupMessage = nil
        operationErrorMessage = nil
        isBulkLookupRunning = true

        let tracksSnapshot = selectedTracks
        let lookupItems: [(key: String, track: Track, query: OnlineTrackMetadataLookupService.Query)] = tracksSnapshot.compactMap { track in
            let needsGenre = track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let needsYear = track.year == nil
            guard needsGenre || needsYear else { return nil }

            return (
                key: bulkLookupKey(for: track),
                track: track,
                query: OnlineTrackMetadataLookupService.Query(
                    title: track.title,
                    artist: track.artist,
                    album: track.album
                )
            )
        }

        Task.detached(priority: .userInitiated) {
            do {
                let candidateMap = try await Self.fetchBulkLookupCandidates(
                    for: lookupItems.map { ($0.key, $0.query) }
                )

                var updates: [(Track, SeratoTrackMetadataUpdate)] = []
                for item in lookupItems {
                    let needsGenre = item.track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let needsYear = item.track.year == nil

                    guard let candidate = candidateMap[item.key] else {
                        continue
                    }

                    var metadata = SeratoTrackMetadataUpdate(
                        title: item.track.title,
                        artist: item.track.artist,
                        album: item.track.album,
                        genre: item.track.genre,
                        comment: item.track.comment,
                        key: item.track.key ?? "",
                        bpm: item.track.bpm,
                        year: item.track.year
                    )

                    if needsGenre, !candidate.genre.isEmpty {
                        metadata.genre = candidate.genre
                    }
                    if needsYear, let year = candidate.year {
                        metadata.year = year
                    }

                    guard metadata.genre != item.track.genre || metadata.year != item.track.year else {
                        continue
                    }

                    updates.append((item.track, metadata))
                }

                let updatedCount = updates.count
                if updatedCount > 0 {
                    try await MainActor.run {
                        if let onApplyMetadataBatch {
                            try onApplyMetadataBatch(updates)
                        } else {
                            for (track, metadata) in updates {
                                try onApplyMetadata(track, metadata)
                            }
                        }
                    }
                }

                await MainActor.run {
                    isBulkLookupRunning = false
                    bulkLookupMessage = updatedCount > 0
                        ? "Updated genre/year for \(updatedCount) track\(updatedCount == 1 ? "" : "s")."
                        : "No missing genre/year values were filled."
                }
            } catch {
                await MainActor.run {
                    isBulkLookupRunning = false
                    operationErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyTopHitMetadataToSelected() {
        guard !selectedTracks.isEmpty else { return }

        bulkLookupMessage = nil
        operationErrorMessage = nil
        isBulkLookupRunning = true

        let tracksSnapshot = selectedTracks
        let onlyFillEmptySnapshot = onlyFillEmpty
        let lookupItems: [(key: String, track: Track, query: OnlineTrackMetadataLookupService.Query)] = tracksSnapshot.map { track in
            (
                key: bulkLookupKey(for: track),
                track: track,
                query: OnlineTrackMetadataLookupService.Query(
                    title: track.title,
                    artist: track.artist,
                    album: track.album
                )
            )
        }

        Task.detached(priority: .userInitiated) {
            do {
                let candidateMap = try await Self.fetchBulkLookupCandidates(
                    for: lookupItems.map { ($0.key, $0.query) }
                )

                var updates: [(Track, SeratoTrackMetadataUpdate)] = []
                for item in lookupItems {
                    guard let candidate = candidateMap[item.key] else {
                        continue
                    }

                    var metadata = SeratoTrackMetadataUpdate(
                        title: item.track.title,
                        artist: item.track.artist,
                        album: item.track.album,
                        genre: item.track.genre,
                        comment: item.track.comment,
                        key: item.track.key ?? "",
                        bpm: item.track.bpm,
                        year: item.track.year
                    )

                    if !candidate.artist.isEmpty,
                              (!onlyFillEmptySnapshot || item.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        metadata.artist = candidate.artist
                    }
                    if !candidate.album.isEmpty,
                              (!onlyFillEmptySnapshot || item.track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        metadata.album = candidate.album
                    }
                    if !candidate.genre.isEmpty,
                              (!onlyFillEmptySnapshot || item.track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        metadata.genre = candidate.genre
                    }
                    if let year = candidate.year,
                              (!onlyFillEmptySnapshot || item.track.year == nil) {
                        metadata.year = year
                    }

                    guard metadata.artist != item.track.artist
                        || metadata.album != item.track.album
                        || metadata.genre != item.track.genre
                        || metadata.year != item.track.year
                    else {
                        continue
                    }

                    updates.append((item.track, metadata))
                }

                await MainActor.run {
                    isBulkLookupRunning = false
                    if updates.isEmpty {
                        bulkLookupMessage = "No top-hit metadata updates were applied."
                        pendingTopHitUpdates = []
                    } else {
                        pendingTopHitUpdates = updates
                        showTopHitConfirmation = true
                    }
                }
            } catch {
                await MainActor.run {
                    isBulkLookupRunning = false
                    operationErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyPendingTopHitUpdates() {
        guard !pendingTopHitUpdates.isEmpty else { return }

        let updates = pendingTopHitUpdates
        pendingTopHitUpdates = []
        bulkLookupMessage = nil
        operationErrorMessage = nil

        let updatedCount = updates.count
        do {
            if let onApplyMetadataBatch {
                try onApplyMetadataBatch(updates)
            } else {
                for (track, metadata) in updates {
                    try onApplyMetadata(track, metadata)
                }
            }
        } catch {
            operationErrorMessage = error.localizedDescription
        }

        if operationErrorMessage == nil {
            bulkLookupMessage = "Applied top-hit artist/album/genre/year to \(updatedCount) track\(updatedCount == 1 ? "" : "s")."
        }
    }

    private static func fetchBulkLookupCandidates(
        for lookups: [(key: String, query: OnlineTrackMetadataLookupService.Query)]
    ) async throws -> [String: OnlineTrackMetadataCandidate] {
        guard !lookups.isEmpty else { return [:] }

        var results: [String: OnlineTrackMetadataCandidate] = [:]
        var iterator = lookups.makeIterator()
        let parallelism = min(8, lookups.count)

        await withTaskGroup(of: (String, OnlineTrackMetadataCandidate?).self) { group in
            func addNextTask() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do {
                        let lookupResults = try await OnlineTrackMetadataLookupService.lookup(
                            query: item.query,
                            sourceSelection: .itunes
                        )
                        return (item.key, lookupResults.first)
                    } catch {
                        return (item.key, nil)
                    }
                }
            }

            for _ in 0..<parallelism {
                addNextTask()
            }

            while let (key, candidate) = await group.next() {
                if let candidate {
                    results[key] = candidate
                }
                addNextTask()
            }
        }

        return results
    }

    private func bulkLookupKey(for track: Track) -> String {
        [track.title, track.artist, track.album]
            .map(normalizedLookupTerm)
            .joined(separator: "|")
    }

    private func normalizedLookupTerm(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while removeTrailingLookupDescriptor(from: &value) {
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.lowercased()
    }

    private func removeTrailingLookupDescriptor(from value: inout String) -> Bool {
        let patterns = [#"\s*\([^()]*\)\s*$"#, #"\s*\[[^\[\]]*\]\s*$"#]

        for pattern in patterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                value.removeSubrange(range)
                return true
            }
        }

        return false
    }

    private func percentText(filled: Int, total: Int) -> String {
        "\(percentValue(filled: filled, total: total))%"
    }

    private func percentValue(filled: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(filled) / Double(total) * 100).rounded())
    }

    private func trend(scopePercent: Int, globalPercent: Int) -> CompletionTrend {
        if scopePercent > globalPercent {
            return .aboveBaseline
        }
        if scopePercent < globalPercent {
            return .belowBaseline
        }
        return .equal
    }

    private func baselineText(globalPercent: Int, scopePercent: Int) -> String {
        let delta = scopePercent - globalPercent
        let deltaPrefix = delta > 0 ? "+" : ""
        return "Global \(globalPercent)% (\(deltaPrefix)\(delta)%)"
    }

    private func statTag(
        title: String,
        valueText: String,
        subtitle: String,
        baseline: String? = nil,
        trend: CompletionTrend = .equal,
        isActive: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? Color.white.opacity(0.92) : .secondary)
            HStack(spacing: 6) {
                Text(valueText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if baseline != nil {
                    Text(trend.symbol)
                        .font(.caption.weight(.bold))
                        .accessibilityLabel(trend.accessibilityLabel)
                }
            }
            .foregroundStyle(isActive ? Color.white : trend.valueColor)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.white.opacity(0.85) : .secondary)
                .lineLimit(1)
            if let baseline {
                Text(baseline)
                    .font(.caption2)
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isActive ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isActive
                        ? Color.accentColor
                        : (trend == .equal ? Color.secondary.opacity(0.25) : trend.valueColor.opacity(0.5)),
                    lineWidth: 1
                )
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

    private func fillSubtitle(field: FillField, filled: Int, total: Int) -> String {
        if fillFilter == field {
            return "Showing \(total - filled) missing"
        }
        return "Scope \(filled)/\(total)"
    }

    private func isFilled(_ field: FillField, _ track: Track) -> Bool {
        switch field {
        case .artist:
            return !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .album:
            return !track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .genre:
            return !track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .year:
            return track.year != nil
        }
    }

    private func toggleFillFilter(_ field: FillField) {
        // Nothing to isolate when every track in scope already has the field.
        let unfilledCount = scopeGenreTracks.filter { !isFilled(field, $0) }.count
        guard unfilledCount > 0 else {
            fillFilter = nil
            return
        }
        fillFilter = (fillFilter == field) ? nil : field
    }

    private func effectiveTrackPaths(for node: CrateNode) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        func collect(_ current: CrateNode) {
            if let crate = current.crate {
                for path in crate.trackPaths where seen.insert(path).inserted {
                    paths.append(path)
                }
            }
            for child in current.children {
                collect(child)
            }
        }

        collect(node)
        return paths
    }

    private func filteredTracks(from tracks: [Track]) -> [Track] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query)
                || track.album.localizedCaseInsensitiveContains(query)
                || track.genre.localizedCaseInsensitiveContains(query)
                || track.fileURL.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    private func filterTree(_ nodes: [CrateNode]) -> [CrateNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }

        return nodes.compactMap { node in
            var copy = node
            copy.children = filterTree(node.children)
            let matchesSelf = node.name.localizedCaseInsensitiveContains(query)
            return (matchesSelf || !copy.children.isEmpty) ? copy : nil
        }
    }

    private func mergedTrees(_ regular: [CrateNode], _ smart: [CrateNode]) -> [CrateNode] {
        var merged: [String: CrateNode] = [:]
        var order: [String] = []

        func insert(_ node: CrateNode) {
            if let existing = merged[node.id] {
                var combined = existing
                if combined.crate == nil {
                    combined.crate = node.crate
                }
                combined.children = mergedTrees(combined.children, node.children)
                merged[node.id] = combined
            } else {
                merged[node.id] = node
                order.append(node.id)
            }
        }

        for node in regular { insert(node) }
        for node in smart { insert(node) }

        return order.compactMap { merged[$0] }
    }

    private func flatten(_ nodes: [CrateNode], into map: inout [String: CrateNode]) {
        for node in nodes {
            map[node.id] = node
            flatten(node.children, into: &map)
        }
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

private extension CrateNode {
    var outlineChildren: [CrateNode]? { children.isEmpty ? nil : children }
}