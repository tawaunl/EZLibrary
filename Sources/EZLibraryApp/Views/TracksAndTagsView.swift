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

    private enum FillField: Hashable, Sendable {
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
    /// Renames the selected files from their tags using the Settings
    /// template. Optional so previews and other call sites can omit it.
    var onBulkRename: (([Track]) -> Void)?
    /// Reloads the library after a trim changed a file or added a new one.
    var onAudioEdited: (() -> Void)?

    @AppStorage("SeratoToolsConfirmTrackDeleteActions") private var confirmDeleteActions = true
    @State private var selectedScopeID: String = Self.allTracksID
    @State private var selectedTracks: [Track] = []
    @State private var metadataLookupTrack: Track?
    @State private var audioEditTrack: Track?
    @State private var audioEditMessage: String?
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
    @EnvironmentObject private var seratoRunning: SeratoRunningModel
    @State private var pendingTagRefreshPlan: LibraryTagRefreshService.Plan?
    @State private var showTagRefreshConfirmation = false
    @State private var showTopHitConfirmation = false
    @State private var pendingWhitespaceFindings: [TagWhitespaceCleanupService.Finding] = []
    @State private var showWhitespaceCleanupConfirmation = false
    @State private var showOnlyFillEmptyPrompt = false
    @State private var showAITagVerification = false

    /// Snapshot of everything derived from `tracks` + the active scope/filters,
    /// recomputed off the main actor only when an input changes (never per
    /// body evaluation). See `scheduleDerivedRecompute`.
    @State private var derived = Derived()
    @State private var derivedRecomputeTask: Task<Void, Never>?
    /// Bumped whenever `derived` (and thus the tracks shown in the table) is
    /// reassigned, so `TrackTableView` can cache its search index and rebuild
    /// it only on real data changes.
    @State private var tableTracksVersion = 0

    /// Everything the sidebar derives from the crate lists, built once per
    /// crate change instead of per read.
    ///
    /// These used to be computed properties. A single body evaluation read them
    /// several times over, and `smartNodeIDs` was read inside the
    /// `OutlineGroup` row builder — so the whole smart-crate hierarchy was
    /// rebuilt and flattened *once per visible row*. At 800 crates that was
    /// ~0.5ms a row, around 15ms of rebuild per render of a 30-row sidebar.
    private struct CrateTrees {
        var combined: [CrateNode] = []
        var nodesByID: [String: CrateNode] = [:]
        var smartNodeIDs: Set<String> = []
    }

    @State private var crateTrees = CrateTrees()

    private var combinedTree: [CrateNode] { crateTrees.combined }
    private var allNodesByID: [String: CrateNode] { crateTrees.nodesByID }
    private var smartNodeIDs: Set<String> { crateTrees.smartNodeIDs }

    private func rebuildCrateTrees() {
        let smart = CrateHierarchy.build(from: libraryService.smartCrates)
        let combined = mergedTrees(CrateHierarchy.build(from: libraryService.crates), smart)

        var nodesByID: [String: CrateNode] = [:]
        flatten(combined, into: &nodesByID)

        var smartNodes: [String: CrateNode] = [:]
        flatten(smart, into: &smartNodes)

        crateTrees = CrateTrees(
            combined: combined,
            nodesByID: nodesByID,
            smartNodeIDs: Set(smartNodes.keys)
        )
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

    // MARK: - Memoized derived data
    //
    // These used to be computed properties that re-ran on every SwiftUI body
    // evaluation. At 50K tracks that was ~10 full O(n) passes per render
    // (several allocating a `trimmingCharacters` copy per element), so any
    // interaction hitched. They now read a cached `Derived` snapshot that is
    // recomputed off the main actor only when its inputs change.

    private struct Derived: Sendable {
        var scopeTracks: [Track] = []
        var scopeGenres: [String] = []
        var scopeGenreTracks: [Track] = []
        var displayedTracks: [Track] = []
        var artistFilledCount = 0
        var albumFilledCount = 0
        var genreFilledCount = 0
        var yearFilledCount = 0
        var globalArtistFilledCount = 0
        var globalAlbumFilledCount = 0
        var globalGenreFilledCount = 0
        var globalYearFilledCount = 0
    }

    private var scopeTracks: [Track] { derived.scopeTracks }
    private var scopeGenres: [String] { derived.scopeGenres }
    private var scopeGenreTracks: [Track] { derived.scopeGenreTracks }
    private var displayedTracks: [Track] { derived.displayedTracks }
    private var artistFilledCount: Int { derived.artistFilledCount }
    private var albumFilledCount: Int { derived.albumFilledCount }
    private var genreFilledCount: Int { derived.genreFilledCount }
    private var yearFilledCount: Int { derived.yearFilledCount }
    private var globalArtistFilledCount: Int { derived.globalArtistFilledCount }
    private var globalAlbumFilledCount: Int { derived.globalAlbumFilledCount }
    private var globalGenreFilledCount: Int { derived.globalGenreFilledCount }
    private var globalYearFilledCount: Int { derived.globalYearFilledCount }

    private var filteredTree: [CrateNode] {
        filterTree(combinedTree)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        tracksVersion: tableTracksVersion,
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
            rebuildCrateTrees()
            if selectedScopeID != Self.allTracksID, allNodesByID[selectedScopeID] == nil {
                selectedScopeID = Self.allTracksID
            }
            scheduleDerivedRecompute()
        }
        // Keyed on the counter rather than the arrays: `onChange(of:)` would
        // compare several hundred `Crate` values, track-path lists included, on
        // every update pass.
        .onChange(of: libraryService.cratesRevision) {
            rebuildCrateTrees()
            if selectedScopeID != Self.allTracksID, allNodesByID[selectedScopeID] == nil {
                selectedScopeID = Self.allTracksID
            }
        }
        .onChange(of: libraryService.revision) {
            scheduleDerivedRecompute()
        }
        .onChange(of: selectedScopeID) {
            selectedGenreFilter = nil
            fillFilter = nil
            scheduleDerivedRecompute()
        }
        .onChange(of: selectedGenreFilter) {
            fillFilter = nil
            scheduleDerivedRecompute()
        }
        .onChange(of: fillFilter) {
            scheduleDerivedRecompute()
        }
        .onChange(of: searchText) {
            if let selectedGenreFilter, !scopeGenres.contains(selectedGenreFilter) {
                self.selectedGenreFilter = nil
            }
            scheduleDerivedRecompute(debounce: true)
        }
        .onDisappear {
            derivedRecomputeTask?.cancel()
            derivedRecomputeTask = nil
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
        .sheet(isPresented: $showAITagVerification) {
            AITagVerificationSheet(tracks: selectedTracks) { updates in
                if let onApplyMetadataBatch {
                    try onApplyMetadataBatch(updates)
                } else {
                    for (track, metadata) in updates {
                        try onApplyMetadata(track, metadata)
                    }
                }
            }
        }
        .sheet(item: $audioEditTrack) { track in
            AudioTrimEditorSheet(
                track: track,
                libraryDirectory: libraryService.libraryDirectory
            ) { summary in
                audioEditMessage = summary
                // The file's length changed and a save-as adds a new record, so
                // the in-memory library is stale either way.
                onAudioEdited?()
            }
        }
        .confirmationDialog(
            "Re-read Tags From Files",
            isPresented: $showTagRefreshConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update \(pendingTagRefreshPlan?.changes.count ?? 0) Track\((pendingTagRefreshPlan?.changes.count ?? 0) == 1 ? "" : "s")") {
                applyPendingTagRefresh()
            }
            Button("Cancel", role: .cancel) {
                pendingTagRefreshPlan = nil
            }
        } message: {
            Text(tagRefreshConfirmationMessage)
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
        .confirmationDialog(
            "Clean Tag Whitespace",
            isPresented: $showWhitespaceCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean \(pendingWhitespaceFindings.count) Track\(pendingWhitespaceFindings.count == 1 ? "" : "s")") {
                applyWhitespaceCleanup()
            }
            Button("Cancel", role: .cancel) {
                pendingWhitespaceFindings = []
            }
        } message: {
            Text(whitespaceCleanupMessage)
        }
        .confirmationDialog(
            "“Only Fill Empty” is On",
            isPresented: $showOnlyFillEmptyPrompt,
            titleVisibility: .visible
        ) {
            Button("Turn Off “Only Fill Empty” & Apply") {
                onlyFillEmpty = false
                applyBulkMetadata()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected tracks already have those fields filled, so nothing changed. Uncheck “Only Fill Empty” to overwrite existing values, or turn it off now to apply.")
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
                Button("Re-read Tags From Files") {
                    prepareTagRefresh()
                }
                .disabled(selectedTracks.isEmpty || isBulkLookupRunning)
                .help("Read each selected file's own tags and correct the library where it disagrees. Nothing is written until you confirm, and a field is only replaced when the file actually has a value for it.")
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
                Button("Verify Tags with AI…") {
                    showAITagVerification = true
                }
                .disabled(selectedTracks.isEmpty || isBulkLookupRunning)
                .help(
                    "Check the selected tracks' tags against their audio fingerprint, the music databases, "
                    + "and a web search. Proposes only the fields a source contradicts, and shows the source "
                    + "for each one before anything is written.")
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

                if let onBulkRename {
                    Divider()
                        .frame(height: 16)
                    Button("Rename Files From Tags") {
                        onBulkRename(selectedTracks)
                    }
                    .disabled(selectedTracks.isEmpty)
                    .help(
                        "Rename the selected files using the filename format from Settings "
                        + "(\(SeratoFeatureFlags.filenameFormatTemplate())), and update Serato to match. "
                        + "Shows what will change before anything is renamed.")
                }

                Divider()
                    .frame(height: 16)

                // Scoped, not selection-based: this is a sweep, and the point
                // is to find padding you can't see well enough to select.
                Button("Clean Tag Whitespace") {
                    prepareWhitespaceCleanup()
                }
                .disabled(scopeTracks.isEmpty || isBulkLookupRunning)
                .help(
                    "Find tag values in \(selectedScopeTitle) with leading or trailing spaces "
                    + "and re-save them trimmed. Shows what will change first.")

                Divider()
                    .frame(height: 16)

                Button("Edit Audio…") {
                    audioEditTrack = selectedTracks.first
                }
                .disabled(selectedTracks.count != 1)
                .help(
                    "Trim silence or unwanted sections off the selected track. "
                    + "Save over the file or write a new one. Select exactly one track.")

                Spacer(minLength: 0)
            }

            if let audioEditMessage {
                Text(audioEditMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
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
        // Every action here writes to the library, and Serato would revert the
        // lot when it quits. Gated as a block so a new action added later is
        // covered without having to remember this.
        .disabled(seratoRunning.isSeratoRunning)
        .help(seratoRunning.isSeratoRunning ? "Quit Serato DJ to edit tags." : "")
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
            if onlyFillEmpty {
                showOnlyFillEmptyPrompt = true
            } else {
                bulkLookupMessage = "No changes were needed for the selected tracks."
            }
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

    // MARK: - Re-read tags from files

    private var tagRefreshConfirmationMessage: String {
        guard let plan = pendingTagRefreshPlan else { return "" }

        var fieldCounts: [String: Int] = [:]
        for change in plan.changes {
            for field in change.fields {
                fieldCounts[field.field, default: 0] += 1
            }
        }
        let breakdown = fieldCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")

        var message = "\(plan.changes.count) track\(plan.changes.count == 1 ? "" : "s") disagree with their file's tags"
        message += breakdown.isEmpty ? "." : " (\(breakdown))."
        message += " \(plan.unchangedCount) already match."
        if !plan.missingFiles.isEmpty {
            message += " \(plan.missingFiles.count) file\(plan.missingFiles.count == 1 ? " is" : "s are") missing from disk and will be skipped."
        }
        if !plan.untaggedFiles.isEmpty {
            message += " \(plan.untaggedFiles.count) file\(plan.untaggedFiles.count == 1 ? " has" : "s have") no tags to read and will be skipped."
        }
        message += " The database is backed up before anything is written."
        return message
    }

    private func prepareTagRefresh() {
        guard !selectedTracks.isEmpty else { return }

        bulkLookupMessage = nil
        operationErrorMessage = nil
        isBulkLookupRunning = true

        let tracksSnapshot = selectedTracks

        Task {
            let plan = await LibraryTagRefreshService.plan(for: tracksSnapshot)

            await MainActor.run {
                isBulkLookupRunning = false
                guard !plan.isEmpty else {
                    pendingTagRefreshPlan = nil
                    bulkLookupMessage = "Every selected track already matches its file's tags."
                    return
                }
                pendingTagRefreshPlan = plan
                showTagRefreshConfirmation = true
            }
        }
    }

    private func applyPendingTagRefresh() {
        guard let plan = pendingTagRefreshPlan else { return }
        pendingTagRefreshPlan = nil

        let updates = plan.changes.map { ($0.track, $0.metadata) }
        do {
            if let onApplyMetadataBatch {
                try onApplyMetadataBatch(updates)
            } else {
                for (track, metadata) in updates {
                    try onApplyMetadata(track, metadata)
                }
            }
            bulkLookupMessage = "Updated \(updates.count) track\(updates.count == 1 ? "" : "s") from their files' tags."
        } catch {
            operationErrorMessage = error.localizedDescription
        }
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
                let lookupOutcome = try await Self.fetchBulkLookupCandidates(
                    for: lookupItems.map { ($0.key, $0.query) }
                )

                var updates: [(Track, SeratoTrackMetadataUpdate)] = []
                for item in lookupItems {
                    let needsGenre = item.track.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let needsYear = item.track.year == nil

                    guard let candidate = lookupOutcome.candidates[item.key] else {
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
                    let summary = updatedCount > 0
                        ? "Updated genre/year for \(updatedCount) track\(updatedCount == 1 ? "" : "s")."
                        : "No missing genre/year values were filled."
                    bulkLookupMessage = summary + (lookupOutcome.failureNote ?? "")
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
                let lookupOutcome = try await Self.fetchBulkLookupCandidates(
                    for: lookupItems.map { ($0.key, $0.query) }
                )

                var updates: [(Track, SeratoTrackMetadataUpdate)] = []
                for item in lookupItems {
                    guard let candidate = lookupOutcome.candidates[item.key] else {
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
                            + (lookupOutcome.failureNote ?? "")
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

    // MARK: - Tag whitespace cleanup

    private var whitespaceCleanupMessage: String {
        var message = TagWhitespaceCleanupService.summary(for: pendingWhitespaceFindings)
        let sample = pendingWhitespaceFindings.prefix(3).map { finding in
            "\(finding.track.fileURL.lastPathComponent) — \(finding.fields.joined(separator: ", "))"
        }
        if !sample.isEmpty {
            message += "\n\n" + sample.joined(separator: "\n")
            if pendingWhitespaceFindings.count > sample.count {
                message += "\n…and \(pendingWhitespaceFindings.count - sample.count) more."
            }
        }
        message += "\n\nFile names aren't changed — only the tag values."
        return message
    }

    /// Scans the current scope and asks before writing anything.
    private func prepareWhitespaceCleanup() {
        operationErrorMessage = nil

        let findings = TagWhitespaceCleanupService.findings(in: scopeTracks)
        guard !findings.isEmpty else {
            pendingWhitespaceFindings = []
            bulkLookupMessage = "No padded tag values in \(selectedScopeTitle)."
            return
        }

        pendingWhitespaceFindings = findings
        showWhitespaceCleanupConfirmation = true
    }

    private func applyWhitespaceCleanup() {
        guard !pendingWhitespaceFindings.isEmpty else { return }

        let updates = TagWhitespaceCleanupService.updates(for: pendingWhitespaceFindings)
        let cleanedCount = updates.count
        pendingWhitespaceFindings = []
        bulkLookupMessage = nil
        operationErrorMessage = nil

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
            bulkLookupMessage = "Trimmed tag whitespace on \(cleanedCount) track\(cleanedCount == 1 ? "" : "s")."
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

    struct BulkLookupOutcome {
        var candidates: [String: OnlineTrackMetadataCandidate] = [:]
        /// Lookups that failed outright, as opposed to simply finding no match.
        var failureCount = 0
        var wasRateLimited = false

        /// Trailing sentence for the completion message, so a run that mostly
        /// failed doesn't read as a library with no matches online.
        var failureNote: String? {
            guard failureCount > 0 else { return nil }
            let tracks = "\(failureCount) track\(failureCount == 1 ? "" : "s")"
            return wasRateLimited
                ? " \(tracks) could not be looked up because the online source is rate limiting — wait a minute and run it again."
                : " \(tracks) could not be looked up because the online source could not be reached."
        }
    }

    private static func fetchBulkLookupCandidates(
        for lookups: [(key: String, query: OnlineTrackMetadataLookupService.Query)]
    ) async throws -> BulkLookupOutcome {
        guard !lookups.isEmpty else { return BulkLookupOutcome() }

        var outcome = BulkLookupOutcome()
        var iterator = lookups.makeIterator()
        // The service paces its own requests, so this only needs to be wide
        // enough to keep that queue fed.
        let parallelism = min(4, lookups.count)

        await withTaskGroup(of: (String, Result<OnlineTrackMetadataCandidate?, Error>).self) { group in
            func addNextTask() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do {
                        let lookupResults = try await OnlineTrackMetadataLookupService.lookup(
                            query: item.query,
                            sourceSelection: .itunes
                        )
                        return (item.key, .success(lookupResults.first))
                    } catch {
                        return (item.key, .failure(error))
                    }
                }
            }

            for _ in 0..<parallelism {
                addNextTask()
            }

            while let (key, result) = await group.next() {
                switch result {
                case let .success(candidate):
                    if let candidate {
                        outcome.candidates[key] = candidate
                    }
                case let .failure(error):
                    outcome.failureCount += 1
                    if let lookupError = error as? OnlineTrackMetadataLookupService.LookupError,
                       lookupError.isRateLimit {
                        outcome.wasRateLimited = true
                    }
                }
                addNextTask()
            }
        }

        return outcome
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
        Self.isFilledStatic(field, track)
    }

    // MARK: - Off-main derived-data recompute

    /// Recomputes the memoized `Derived` snapshot off the main actor, snapping
    /// the current inputs first. Coalesces rapid triggers by cancelling any
    /// in-flight recompute; `debounce` adds a short delay for fast-changing
    /// inputs like the search field.
    private func scheduleDerivedRecompute(debounce: Bool = false) {
        derivedRecomputeTask?.cancel()

        let allTracks = libraryService.tracks
        let selectedPaths: [String]? = selectedNode.map { effectiveTrackPaths(for: $0) }
        let genre = selectedGenreFilter
        let fill = fillFilter
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        derivedRecomputeTask = Task(priority: .userInitiated) {
            if debounce {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }

            let result = await Self.computeDerivedAsync(
                allTracks: allTracks,
                selectedPaths: selectedPaths,
                genre: genre,
                fill: fill,
                query: query
            )

            guard !Task.isCancelled else { return }
            derived = result
            tableTracksVersion &+= 1
        }
    }

    nonisolated private static func computeDerivedAsync(
        allTracks: [Track],
        selectedPaths: [String]?,
        genre: String?,
        fill: FillField?,
        query: String
    ) async -> Derived {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: computeDerived(
                    allTracks: allTracks,
                    selectedPaths: selectedPaths,
                    genre: genre,
                    fill: fill,
                    query: query
                ))
            }
        }
    }

    nonisolated private static func computeDerived(
        allTracks: [Track],
        selectedPaths: [String]?,
        genre: String?,
        fill: FillField?,
        query: String
    ) -> Derived {
        let base: [Track]
        if let selectedPaths {
            let resolver = TrackPathResolver(tracks: allTracks)
            base = selectedPaths.compactMap { resolver.resolve(path: $0) }
        } else {
            base = allTracks
        }

        let scope: [Track]
        if query.isEmpty {
            scope = base
        } else {
            scope = TrackTextSearch.filter(base, query: query, includeFileName: true)
        }

        let whitespace = CharacterSet.whitespacesAndNewlines
        let genres = Array(Set(scope
            .map { $0.genre.trimmingCharacters(in: whitespace) }
            .filter { !$0.isEmpty })).sorted()

        let scopeGenre = genre.map { value in scope.filter { $0.genre == value } } ?? scope
        let displayed = fill.map { field in scopeGenre.filter { !isFilledStatic(field, $0) } } ?? scopeGenre

        let scopeCounts = fillCounts(in: scopeGenre)
        let globalCounts = fillCounts(in: allTracks)

        var result = Derived()
        result.scopeTracks = scope
        result.scopeGenres = genres
        result.scopeGenreTracks = scopeGenre
        result.displayedTracks = displayed
        result.artistFilledCount = scopeCounts.artist
        result.albumFilledCount = scopeCounts.album
        result.genreFilledCount = scopeCounts.genre
        result.yearFilledCount = scopeCounts.year
        result.globalArtistFilledCount = globalCounts.artist
        result.globalAlbumFilledCount = globalCounts.album
        result.globalGenreFilledCount = globalCounts.genre
        result.globalYearFilledCount = globalCounts.year
        return result
    }

    /// Counts how many tracks have each fillable field populated, in a single
    /// pass. This recomputes on every search keystroke, so it walks the array
    /// once for all four fields rather than four times over.
    nonisolated private static func fillCounts(
        in tracks: [Track]
    ) -> (artist: Int, album: Int, genre: Int, year: Int) {
        var artist = 0, album = 0, genre = 0, year = 0
        for track in tracks {
            if hasContent(track.artist) { artist += 1 }
            if hasContent(track.album) { album += 1 }
            if hasContent(track.genre) { genre += 1 }
            if track.year != nil { year += 1 }
        }
        return (artist, album, genre, year)
    }

    /// Whether `value` holds anything other than whitespace — equivalent to
    /// `!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, but
    /// without allocating a trimmed copy of every field of every track.
    @inline(__always)
    nonisolated private static func hasContent(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
                continue
            default:
                // Below U+0085 nothing else is whitespace, so the common case
                // never has to consult the character set.
                if scalar.value < 0x85 { return true }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            }
        }
        return false
    }

    nonisolated private static func isFilledStatic(_ field: FillField, _ track: Track) -> Bool {
        switch field {
        case .artist:
            return hasContent(track.artist)
        case .album:
            return hasContent(track.album)
        case .genre:
            return hasContent(track.genre)
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