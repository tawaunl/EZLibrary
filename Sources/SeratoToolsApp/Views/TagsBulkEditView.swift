import SwiftUI
import SeratoToolsCore

struct TagsBulkEditView: View {
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

    @EnvironmentObject private var libraryService: LibraryService

    let onApplyMetadata: (Track, SeratoTrackMetadataUpdate) throws -> Void

    @State private var selectedScopeID: String = Self.allTracksID
    @State private var selectedTracks: [Track] = []
    @State private var metadataLookupTrack: Track?
    @State private var searchText = ""
    @State private var bulkArtist = ""
    @State private var bulkAlbum = ""
    @State private var bulkGenre = ""
    @State private var bulkYear = ""
    @State private var onlyFillEmpty = true
    @State private var isBulkLookupRunning = false
    @State private var bulkLookupMessage: String?
    @State private var operationErrorMessage: String?

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

    private var displayedTracks: [Track] {
        guard let selectedNode else {
            return filteredTracks(from: libraryService.tracks)
        }

        let resolver = TrackPathResolver(tracks: libraryService.tracks)
        let selectedPaths = effectiveTrackPaths(for: selectedNode)
        let tracks = selectedPaths.compactMap { resolver.resolve(path: $0) }
        return filteredTracks(from: tracks)
    }

    private var filteredTree: [CrateNode] {
        filterTree(combinedTree)
    }

    private var artistFilledCount: Int {
        displayedTracks.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var albumFilledCount: Int {
        displayedTracks.filter { !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var genreFilledCount: Int {
        displayedTracks.filter { !$0.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var yearFilledCount: Int {
        displayedTracks.filter { $0.year != nil }.count
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
                title: "Tags",
                description: "Bulk-fill missing artist, album, genre, and year metadata across the scope you choose, then apply lookup results track by track.",
                icon: "tag"
            )

            HSplitView {
                crateListPane
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)

                VStack(alignment: .leading, spacing: 10) {
                    statsHeader
                    bulkEditor
                    selectionStatusBar

                    TrackTableView(
                        tracks: displayedTracks,
                        numberingMode: .listOrder,
                        onMetadataEditRequested: { track, metadata in
                            do {
                                try onApplyMetadata(track, metadata)
                            } catch {
                                operationErrorMessage = error.localizedDescription
                            }
                        },
                        onSelectionChanged: { selected in
                            selectedTracks = selected
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
    }

    private var crateListPane: some View {
        VStack(spacing: 8) {
            TextField("Search tags scope", text: $searchText)
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
        let scopeArtistPercent = percentValue(filled: artistFilledCount, total: displayedTracks.count)
        let scopeAlbumPercent = percentValue(filled: albumFilledCount, total: displayedTracks.count)
        let scopeGenrePercent = percentValue(filled: genreFilledCount, total: displayedTracks.count)
        let scopeYearPercent = percentValue(filled: yearFilledCount, total: displayedTracks.count)
        let globalArtistPercent = percentValue(filled: globalArtistFilledCount, total: libraryService.tracks.count)
        let globalAlbumPercent = percentValue(filled: globalAlbumFilledCount, total: libraryService.tracks.count)
        let globalGenrePercent = percentValue(filled: globalGenreFilledCount, total: libraryService.tracks.count)
        let globalYearPercent = percentValue(filled: globalYearFilledCount, total: libraryService.tracks.count)

        return HStack(spacing: 10) {
            statTag(title: "Tracks", valueText: "\(displayedTracks.count)", subtitle: selectedScopeTitle)
            statTag(
                title: "Artist Filled",
                valueText: percentText(filled: artistFilledCount, total: displayedTracks.count),
                subtitle: "Scope \(artistFilledCount)/\(displayedTracks.count)",
                baseline: baselineText(globalPercent: globalArtistPercent, scopePercent: scopeArtistPercent),
                trend: trend(scopePercent: scopeArtistPercent, globalPercent: globalArtistPercent)
            )
            statTag(
                title: "Album Filled",
                valueText: percentText(filled: albumFilledCount, total: displayedTracks.count),
                subtitle: "Scope \(albumFilledCount)/\(displayedTracks.count)",
                baseline: baselineText(globalPercent: globalAlbumPercent, scopePercent: scopeAlbumPercent),
                trend: trend(scopePercent: scopeAlbumPercent, globalPercent: globalAlbumPercent)
            )
            statTag(
                title: "Genre Filled",
                valueText: percentText(filled: genreFilledCount, total: displayedTracks.count),
                subtitle: "Scope \(genreFilledCount)/\(displayedTracks.count)",
                baseline: baselineText(globalPercent: globalGenrePercent, scopePercent: scopeGenrePercent),
                trend: trend(scopePercent: scopeGenrePercent, globalPercent: globalGenrePercent)
            )
            statTag(
                title: "Year Filled",
                valueText: percentText(filled: yearFilledCount, total: displayedTracks.count),
                subtitle: "Scope \(yearFilledCount)/\(displayedTracks.count)",
                baseline: baselineText(globalPercent: globalYearPercent, scopePercent: scopeYearPercent),
                trend: trend(scopePercent: scopeYearPercent, globalPercent: globalYearPercent)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .glowCardStyle(radius: 8, opacity: 0.05)
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
                Button("Fill Missing Genre/Year") {
                    lookupMissingGenreAndYear()
                }
                .disabled(selectedTracks.isEmpty || isBulkLookupRunning)
                if isBulkLookupRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Toggle("Only Fill Empty", isOn: $onlyFillEmpty)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

            do {
                try onApplyMetadata(track, metadata)
            } catch {
                operationErrorMessage = error.localizedDescription
                return
            }
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

                var updatedCount = 0
                for (track, metadata) in updates {
                    try await MainActor.run {
                        try onApplyMetadata(track, metadata)
                    }
                    updatedCount += 1
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
        trend: CompletionTrend = .equal
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .foregroundStyle(trend.valueColor)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let baseline {
                Text(baseline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    trend == .equal ? Color.secondary.opacity(0.25) : trend.valueColor.opacity(0.5),
                    lineWidth: 1
                )
        )
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