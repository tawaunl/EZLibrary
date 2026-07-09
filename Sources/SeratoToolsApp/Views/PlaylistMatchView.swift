import SwiftUI
import AppKit
import SeratoToolsCore

struct PlaylistMatchView: View {
    fileprivate enum BulkVersionPreference: String, CaseIterable, Identifiable {
        case auto
        case djOrder
        case intro
        case extended
        case instrumental
        case acapella
        case clean
        case dirty
        case radio
        case edit
        case mix

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto:
                return "Keep Current"
            case .djOrder:
                return "Prefer DJ Version Order"
            case .intro:
                return "Prefer Intro"
            case .extended:
                return "Prefer Extended"
            case .instrumental:
                return "Prefer Instrumental"
            case .acapella:
                return "Prefer Acapella"
            case .clean:
                return "Prefer Clean"
            case .dirty:
                return "Prefer Dirty"
            case .radio:
                return "Prefer Radio"
            case .edit:
                return "Prefer Edit"
            case .mix:
                return "Prefer Mix"
            }
        }
    }

    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var rawInput = ""
    @State private var crateName = "PlaylistMatch"
    @State private var detectedPlaylistName: String?
    @State private var parserDiagnostics: PlaylistMatchService.ParserDiagnostics?
    @State private var isRunning = false
    @State private var isCreatingCrate = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var resolvedEntries: [PlaylistMatchService.PlaylistEntry] = []
    @State private var matchedEntries: [PlaylistMatchService.MatchedEntry] = []
    @State private var includedMatchedEntryIDs: Set<UUID> = []
    @State private var selectedVersionByEntryID: [UUID: UUID] = [:]
    @State private var bulkVersionPreference: BulkVersionPreference = .auto
    @State private var showOnlyUncheckedMatches = false
    @State private var matchedTracks: [Track] = []
    @State private var planItems: [PlaylistMatchService.PlanItem] = []
    @State private var resolvedEntryCount = 0
    @State private var youtubeURLByPlanID: [UUID: String] = [:]
    @State private var rippingPlanIDs: Set<UUID> = []
    @State private var planStatusByID: [UUID: String] = [:]
    @State private var searchingPlanIDs: Set<UUID> = []
    @State private var youtubeSuggestionsByPlanID: [UUID: [YouTubeAudioImportService.SearchResult]] = [:]
    @State private var hoveredSuggestionKey: String?
    @State private var matchedYoutubeURLByEntryID: [UUID: String] = [:]
    @State private var matchedStatusByEntryID: [UUID: String] = [:]
    @State private var matchedSearchingEntryIDs: Set<UUID> = []
    @State private var matchedRippingEntryIDs: Set<UUID> = []
    @State private var matchedSuggestionsByEntryID: [UUID: [YouTubeAudioImportService.SearchResult]] = [:]
    @State private var hoveredMatchedSuggestionKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeaderCard(
                    title: "PlaylistMatch",
                    description: "Paste a Spotify playlist link, text list, or CSV. PlaylistMatch scans your Serato library, builds a crate from matches, and keeps unmatched tracks in a Plan.",
                    icon: "music.quarternote.3"
                )

                inputCard
                summaryCard
                planCard
            }
            .padding(16)
        }
        .onAppear {
            restoreCachedStateIfNeeded()
        }
        .onDisappear {
            cacheCurrentState()
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Playlist Input")
                .font(.title3.weight(.semibold))

            TextEditor(text: $rawInput)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            Text("Input examples: Spotify playlist URL, CSV with Title/Artist columns, or lines like 'Artist - Title'.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let detectedPlaylistName {
                Text("Playlist: \(detectedPlaylistName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let parserDiagnostics {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Parser Diagnostics")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Source: \(parserDiagnostics.chosenSource)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Counts - api: \(parserDiagnostics.apiEntriesCount), main: \(parserDiagnostics.htmlEntriesCount), embed: \(parserDiagnostics.embedEntriesCount), chosen: \(parserDiagnostics.chosenEntriesCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Rows with artist in chosen set: \(parserDiagnostics.chosenRowsWithArtistCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 10) {
                TextField("Crate name", text: $crateName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Button(isRunning ? "Scanning..." : "Scan Playlist") {
                    runMatch()
                }
                .disabled(isRunning)

                Button("Clear") {
                    clearResults()
                }
                .disabled(isRunning)

                Button("Save Plan") {
                    savePlanToDisk()
                }
                .disabled(planItems.isEmpty || isRunning)

                Button("Load Plan") {
                    loadPlanFromDisk()
                }
                .disabled(isRunning)

                Spacer(minLength: 0)
            }

            if let successMessage {
                Text(successMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match Summary")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                statTag(title: "Playlist Tracks", value: "\(resolvedEntryCount)")
                statTag(title: "Matched Songs", value: "\(matchedEntries.count)", accent: true)
                statTag(title: "Chosen Songs", value: "\(includedMatchedEntryIDs.count)")
                statTag(title: "Selected Tracks", value: "\(matchedTracks.count)")
                statTag(title: "Plan", value: "\(planItems.count)")
                Spacer(minLength: 0)
            }

            Button(isCreatingCrate ? "Creating Crate..." : "Create Crate From Matches") {
                createCrateFromMatches()
            }
            .disabled(isCreatingCrate || matchedTracks.isEmpty)

            HStack(spacing: 8) {
                Picker("Bulk Version", selection: $bulkVersionPreference) {
                    ForEach(BulkVersionPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)

                Button("Apply To All") {
                    applyBulkVersionPreference()
                }
                .disabled(matchedEntries.isEmpty)

                Button("Select All") {
                    includedMatchedEntryIDs = Set(matchedEntries.map { $0.entry.id })
                    matchedTracks = selectedMatchedTracks(from: matchedEntries)
                }
                .disabled(matchedEntries.isEmpty)

                Button("Select None") {
                    includedMatchedEntryIDs.removeAll()
                    matchedTracks = []
                }
                .disabled(matchedEntries.isEmpty)

                Toggle("Show Unchecked Only", isOn: $showOnlyUncheckedMatches)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(matchedEntries.isEmpty)

                Spacer(minLength: 0)
            }

            if !matchedEntries.isEmpty {
                let visibleEntries = showOnlyUncheckedMatches
                    ? matchedEntries.filter { !includedMatchedEntryIDs.contains($0.entry.id) }
                    : matchedEntries

                if visibleEntries.isEmpty {
                    Text("All matched songs are currently included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(visibleEntries.prefix(20))) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            let artist = item.entry.artist.isEmpty ? "Unknown Artist" : item.entry.artist
                            Text("• \(artist) - \(item.entry.title)")
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)

                            Text("Versions in library: \(item.versions.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Text("\(item.confidence.displayName) Confidence")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(confidenceColor(item.confidence).opacity(0.18))
                                    )
                                    .foregroundStyle(confidenceColor(item.confidence))

                                Text(item.reason.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer(minLength: 0)

                                Toggle("Include", isOn: includeBinding(for: item))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }

                            Picker(
                                "Selected Version",
                                selection: selectedVersionBinding(for: item)
                            ) {
                                ForEach(item.versions, id: \.id) { version in
                                    Text(versionPickerTitle(for: version))
                                        .tag(version.id.uuidString)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 440, alignment: .leading)

                            if !includedMatchedEntryIDs.contains(item.entry.id) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Unchecked match: search and link a YouTube source if you want to add a new rip instead.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        TextField(
                                            "Paste YouTube URL",
                                            text: Binding(
                                                get: { matchedYoutubeURLByEntryID[item.entry.id] ?? "" },
                                                set: { matchedYoutubeURLByEntryID[item.entry.id] = $0 }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)

                                        Button(matchedSearchingEntryIDs.contains(item.entry.id) ? "Finding..." : "Find In-App") {
                                            searchYouTubeSuggestions(for: item.entry)
                                        }
                                        .disabled(matchedSearchingEntryIDs.contains(item.entry.id))

                                        Button("Search YouTube") {
                                            openYouTubeSearch(for: item.entry)
                                        }

                                        Button(matchedRippingEntryIDs.contains(item.entry.id) ? "Ripping..." : "Rip + Add") {
                                            ripMatchedEntryFromYouTube(item.entry)
                                        }
                                        .disabled(matchedRippingEntryIDs.contains(item.entry.id))
                                    }

                                    if let suggestions = matchedSuggestionsByEntryID[item.entry.id], !suggestions.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Suggestions")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            ForEach(Array(suggestions.prefix(5))) { suggestion in
                                                let isHovered = hoveredMatchedSuggestionKey == matchedSuggestionRowKey(entryID: item.entry.id, suggestionID: suggestion.id)
                                                HStack(alignment: .top, spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(suggestion.title)
                                                            .font(.caption)
                                                            .lineLimit(1)
                                                        Text(suggestion.channel)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                    }

                                                    Spacer(minLength: 0)

                                                    HStack(spacing: 6) {
                                                        Button("Use Link") {
                                                            matchedYoutubeURLByEntryID[item.entry.id] = suggestion.webpageURL.absoluteString
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .controlSize(.small)

                                                        Button(matchedRippingEntryIDs.contains(item.entry.id) ? "Ripping..." : "Use + Rip") {
                                                            ripMatchedEntryFromYouTube(item.entry, preferredURL: suggestion.webpageURL)
                                                        }
                                                        .buttonStyle(.borderedProminent)
                                                        .controlSize(.small)
                                                        .disabled(matchedRippingEntryIDs.contains(item.entry.id))
                                                    }
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 5)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                                    )
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                                    )
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 7)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color.accentColor.opacity(isHovered ? 0.18 : 0.08))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.accentColor.opacity(isHovered ? 0.42 : 0.22), lineWidth: 1)
                                                )
                                                .onHover { hovering in
                                                    let key = matchedSuggestionRowKey(entryID: item.entry.id, suggestionID: suggestion.id)
                                                    hoveredMatchedSuggestionKey = hovering ? key : (hoveredMatchedSuggestionKey == key ? nil : hoveredMatchedSuggestionKey)
                                                }
                                            }
                                        }
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                                        )
                                    }

                                    if let status = matchedStatusByEntryID[item.entry.id] {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.45))
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(item.versions.prefix(6)), id: \.id) { version in
                                    HStack(spacing: 6) {
                                        Text(versionLabel(for: version))
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(Color.accentColor.opacity(0.14))
                                            )
                                        Text(version.title.isEmpty ? version.fileURL.lastPathComponent : version.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }

                                if item.versions.count > 6 {
                                    Text("+ \(item.versions.count - 6) more versions")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        }

                        if visibleEntries.count > 20 {
                            Text("+ \(visibleEntries.count - 20) more matched songs")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan")
                .font(.title3.weight(.semibold))

            if planItems.isEmpty {
                Text("No gaps found. Your matched crate can be created as-is.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Tracks PlaylistMatch couldn't find in your library:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Use Search YouTube to find a source, paste the video link, then Rip + Add to bring it into this crate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(planItems) { item in
                    let artist = item.entry.artist.isEmpty ? "Unknown Artist" : item.entry.artist
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• \(artist) - \(item.entry.title)")
                            .font(.callout.weight(.semibold))

                        HStack(spacing: 8) {
                            TextField(
                                "Paste YouTube URL",
                                text: Binding(
                                    get: { youtubeURLByPlanID[item.id] ?? "" },
                                    set: { youtubeURLByPlanID[item.id] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            Button(searchingPlanIDs.contains(item.id) ? "Finding..." : "Find In-App") {
                                searchYouTubeSuggestions(for: item)
                            }
                            .disabled(searchingPlanIDs.contains(item.id))

                            Button("Search YouTube") {
                                openYouTubeSearch(for: item.entry)
                            }

                            Button(rippingPlanIDs.contains(item.id) ? "Ripping..." : "Rip + Add") {
                                ripPlanItemFromYouTube(item)
                            }
                            .disabled(rippingPlanIDs.contains(item.id))
                        }

                        if let suggestions = youtubeSuggestionsByPlanID[item.id], !suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Suggestions")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(suggestions.prefix(5))) { suggestion in
                                    let isHovered = hoveredSuggestionKey == suggestionRowKey(planID: item.id, suggestionID: suggestion.id)
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.title)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Text(suggestion.channel)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer(minLength: 0)

                                        HStack(spacing: 6) {
                                            Button("Use Link") {
                                                youtubeURLByPlanID[item.id] = suggestion.webpageURL.absoluteString
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button(rippingPlanIDs.contains(item.id) ? "Ripping..." : "Use + Rip") {
                                                ripPlanItemFromYouTube(item, preferredURL: suggestion.webpageURL)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .disabled(rippingPlanIDs.contains(item.id))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(isHovered ? 0.18 : 0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(isHovered ? 0.42 : 0.22), lineWidth: 1)
                                    )
                                    .onHover { hovering in
                                        let key = suggestionRowKey(planID: item.id, suggestionID: suggestion.id)
                                        hoveredSuggestionKey = hovering ? key : (hoveredSuggestionKey == key ? nil : hoveredSuggestionKey)
                                    }
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                            )
                        }

                        if let status = planStatusByID[item.id] {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private func statTag(title: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(accent ? .white.opacity(0.92) : .secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(accent ? .white : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func clearResults() {
        resolvedEntries = []
        resolvedEntryCount = 0
        matchedEntries = []
        includedMatchedEntryIDs = []
        selectedVersionByEntryID = [:]
        showOnlyUncheckedMatches = false
        matchedTracks = []
        planItems = []
        detectedPlaylistName = nil
        parserDiagnostics = nil
        youtubeURLByPlanID = [:]
        rippingPlanIDs = []
        planStatusByID = [:]
        searchingPlanIDs = []
        youtubeSuggestionsByPlanID = [:]
        hoveredSuggestionKey = nil
        matchedYoutubeURLByEntryID = [:]
        matchedStatusByEntryID = [:]
        matchedSearchingEntryIDs = []
        matchedRippingEntryIDs = []
        matchedSuggestionsByEntryID = [:]
        hoveredMatchedSuggestionKey = nil
        successMessage = nil
        errorMessage = nil
    }

    private func suggestionRowKey(planID: UUID, suggestionID: String) -> String {
        "\(planID.uuidString)|\(suggestionID)"
    }

    private func matchedSuggestionRowKey(entryID: UUID, suggestionID: String) -> String {
        "\(entryID.uuidString)|\(suggestionID)"
    }

    private func confidenceColor(_ confidence: PlaylistMatchService.MatchConfidence) -> Color {
        switch confidence {
        case .high:
            return .green
        case .medium:
            return .orange
        case .low:
            return .red
        }
    }

    private func runMatch() {
        isRunning = true
        successMessage = nil
        errorMessage = nil

        let input = rawInput
        let libraryTracks = libraryService.tracks

        Task {
            do {
                let resolved = try await PlaylistMatchService.resolvePlaylist(from: input)
                let result = PlaylistMatchService.match(entries: resolved.entries, libraryTracks: libraryTracks)
                resolvedEntries = resolved.entries
                resolvedEntryCount = resolved.entries.count
                detectedPlaylistName = resolved.playlistName
                parserDiagnostics = resolved.diagnostics
                matchedEntries = result.matchedEntries
                includedMatchedEntryIDs = Set(result.matchedEntries.map { $0.entry.id })
                selectedVersionByEntryID = Dictionary(
                    uniqueKeysWithValues: result.matchedEntries.map { ($0.entry.id, $0.primaryTrack.id) }
                )
                matchedTracks = selectedMatchedTracks(from: result.matchedEntries)
                planItems = result.planItems
                youtubeURLByPlanID = Dictionary(uniqueKeysWithValues: result.planItems.map { ($0.id, "") })
                planStatusByID = [:]
                youtubeSuggestionsByPlanID = [:]
                matchedYoutubeURLByEntryID = [:]
                matchedStatusByEntryID = [:]
                matchedSearchingEntryIDs = []
                matchedRippingEntryIDs = []
                matchedSuggestionsByEntryID = [:]
                if let playlistName = resolved.playlistName,
                   (crateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || crateName == "PlaylistMatch") {
                    crateName = playlistName
                }
                successMessage = "Matched \(result.matchedEntries.count) songs. Added \(result.planItems.count) to Plan."
            } catch {
                errorMessage = error.localizedDescription
            }

            isRunning = false
        }
    }

    private func createCrateFromMatches() {
        guard !matchedTracks.isEmpty else { return }
        isCreatingCrate = true
        errorMessage = nil

        do {
            let crateURL = try upsertTargetCrateFromCurrentSelection()
            onLibraryChanged()
            successMessage = "Updated crate \(crateURL.deletingPathExtension().lastPathComponent) with \(matchedTracks.count) selected playlist tracks in order."
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreatingCrate = false
    }

    private func selectedVersionBinding(for item: PlaylistMatchService.MatchedEntry) -> Binding<String> {
        Binding(
            get: {
                let selectedID = selectedVersionByEntryID[item.entry.id] ?? item.primaryTrack.id
                return selectedID.uuidString
            },
            set: { newValue in
                guard let trackID = UUID(uuidString: newValue) else { return }
                selectedVersionByEntryID[item.entry.id] = trackID
                matchedTracks = selectedMatchedTracks(from: matchedEntries)
            }
        )
    }

    private func includeBinding(for item: PlaylistMatchService.MatchedEntry) -> Binding<Bool> {
        Binding(
            get: { includedMatchedEntryIDs.contains(item.entry.id) },
            set: { included in
                if included {
                    includedMatchedEntryIDs.insert(item.entry.id)
                } else {
                    includedMatchedEntryIDs.remove(item.entry.id)
                }
                matchedTracks = selectedMatchedTracks(from: matchedEntries)
            }
        )
    }

    private func selectedMatchedTracks(from entries: [PlaylistMatchService.MatchedEntry]) -> [Track] {
        var output: [Track] = []
        var seen = Set<String>()

        for entry in entries {
            guard includedMatchedEntryIDs.contains(entry.entry.id) else { continue }
            let selectedTrackID = selectedVersionByEntryID[entry.entry.id] ?? entry.primaryTrack.id
            let selectedTrack = entry.versions.first(where: { $0.id == selectedTrackID }) ?? entry.primaryTrack
            if seen.insert(selectedTrack.seratoStoredPath).inserted {
                output.append(selectedTrack)
            }
        }

        return output
    }

    private func versionPickerTitle(for track: Track) -> String {
        let artist = track.artist.isEmpty ? "Unknown Artist" : track.artist
        let title = track.title.isEmpty ? track.fileURL.lastPathComponent : track.title
        return "\(versionLabel(for: track)) • \(artist) - \(title)"
    }

    private func applyBulkVersionPreference() {
        guard !matchedEntries.isEmpty else { return }

        switch bulkVersionPreference {
        case .auto:
            for entry in matchedEntries {
                selectedVersionByEntryID[entry.entry.id] = entry.primaryTrack.id
            }
        case .djOrder:
            for entry in matchedEntries {
                if let preferred = preferredDJOrderVersion(in: entry.versions) {
                    selectedVersionByEntryID[entry.entry.id] = preferred.id
                } else {
                    selectedVersionByEntryID[entry.entry.id] = entry.primaryTrack.id
                }
            }
        default:
            for entry in matchedEntries {
                if let preferred = preferredVersion(in: entry.versions, preference: bulkVersionPreference) {
                    selectedVersionByEntryID[entry.entry.id] = preferred.id
                } else {
                    selectedVersionByEntryID[entry.entry.id] = entry.primaryTrack.id
                }
            }
        }

        matchedTracks = selectedMatchedTracks(from: matchedEntries)
        successMessage = "Applied \(bulkVersionPreference.displayName) across matched songs."
    }

    private func savePlanToDisk() {
        guard !planItems.isEmpty else {
            errorMessage = PlaylistMatchService.PlanPersistenceError.emptyPlan.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Save PlaylistMatch Plan"
        panel.prompt = "Save Plan"
        panel.nameFieldStringValue = "PlaylistMatch-Plan.playlistmatch-plan.json"
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try PlaylistMatchService.savePlan(planItems, to: destinationURL)
            successMessage = "Saved \(planItems.count) plan items to \(destinationURL.lastPathComponent)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPlanFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load Plan"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            let loaded = try PlaylistMatchService.loadPlan(from: selectedURL)
            planItems = loaded
            youtubeURLByPlanID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, "") })
            planStatusByID = [:]
            searchingPlanIDs = []
            rippingPlanIDs = []
            youtubeSuggestionsByPlanID = [:]
            successMessage = "Loaded \(loaded.count) plan items from \(selectedURL.lastPathComponent)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preferredDJOrderVersion(in versions: [Track]) -> Track? {
        // Priority order: Intro > Extended > Clean > Dirty > Radio > Original/default.
        if let intro = versions.first(where: { matches($0, preference: .intro) }) {
            return intro
        }
        if let extended = versions.first(where: { matches($0, preference: .extended) }) {
            return extended
        }
        if let clean = versions.first(where: { matches($0, preference: .clean) }) {
            return clean
        }
        if let dirty = versions.first(where: { matches($0, preference: .dirty) }) {
            return dirty
        }
        if let radio = versions.first(where: { matches($0, preference: .radio) }) {
            return radio
        }
        return versions.first
    }

    private func preferredVersion(in versions: [Track], preference: BulkVersionPreference) -> Track? {
        versions.first(where: { matches($0, preference: preference) })
    }

    private func matches(_ track: Track, preference: BulkVersionPreference) -> Bool {
        let title = track.title.lowercased()

        switch preference {
        case .auto:
            return false
        case .djOrder:
            return false
        case .intro:
            return title.contains("intro")
        case .extended:
            return title.contains("extended")
        case .instrumental:
            return title.contains("instrumental")
        case .acapella:
            return title.contains("acapella") || title.contains("a cappella")
        case .clean:
            return title.contains("clean")
        case .dirty:
            return title.contains("dirty")
        case .radio:
            return title.contains("radio")
        case .edit:
            return title.contains("edit")
        case .mix:
            return title.contains("mix")
        }
    }

    private func openYouTubeSearch(for entry: PlaylistMatchService.PlaylistEntry) {
        let query = [entry.artist, entry.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else { return }
        guard var components = URLComponents(string: "https://www.youtube.com/results") else { return }
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let searchURL = components.url else { return }
        NSWorkspace.shared.open(searchURL)
    }

    private func searchYouTubeSuggestions(for item: PlaylistMatchService.PlanItem) {
        let query = [item.entry.artist, item.entry.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else {
            planStatusByID[item.id] = "Missing title/artist for search query."
            return
        }

        searchingPlanIDs.insert(item.id)
        planStatusByID[item.id] = "Searching YouTube..."

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.searchVideos(query: query, maxResults: 5)
                }.value

                youtubeSuggestionsByPlanID[item.id] = suggestions
                if suggestions.isEmpty {
                    planStatusByID[item.id] = "No suggestions found."
                } else {
                    planStatusByID[item.id] = "Found \(suggestions.count) suggestions."
                }
            } catch {
                planStatusByID[item.id] = "Search failed: \(error.localizedDescription)"
            }

            searchingPlanIDs.remove(item.id)
        }
    }

    private func searchYouTubeSuggestions(for entry: PlaylistMatchService.PlaylistEntry) {
        let query = [entry.artist, entry.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else {
            matchedStatusByEntryID[entry.id] = "Missing title/artist for search query."
            return
        }

        matchedSearchingEntryIDs.insert(entry.id)
        matchedStatusByEntryID[entry.id] = "Searching YouTube..."

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.searchVideos(query: query, maxResults: 5)
                }.value

                matchedSuggestionsByEntryID[entry.id] = suggestions
                if suggestions.isEmpty {
                    matchedStatusByEntryID[entry.id] = "No suggestions found."
                } else {
                    matchedStatusByEntryID[entry.id] = "Found \(suggestions.count) suggestions."
                }
            } catch {
                matchedStatusByEntryID[entry.id] = "Search failed: \(error.localizedDescription)"
            }

            matchedSearchingEntryIDs.remove(entry.id)
        }
    }

    private func ripPlanItemFromYouTube(_ item: PlaylistMatchService.PlanItem, preferredURL: URL? = nil) {
        let selectedURL: URL?
        if let preferredURL {
            selectedURL = preferredURL
            youtubeURLByPlanID[item.id] = preferredURL.absoluteString
        } else {
            let rawURL = youtubeURLByPlanID[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            selectedURL = YouTubeBatchLinkImportService.parseVideoURLs(from: rawURL).first
        }

        guard let videoURL = selectedURL else {
            errorMessage = PlaylistMatchRipError.invalidYouTubeURL.localizedDescription
            return
        }

        let dependencyStatus = YouTubeAudioImportService.dependencyStatus()
        guard dependencyStatus.isReady else {
            errorMessage = PlaylistMatchRipError.dependenciesMissing.localizedDescription
            return
        }

        errorMessage = nil
        successMessage = nil
        rippingPlanIDs.insert(item.id)
        planStatusByID[item.id] = "Downloading from YouTube..."

        let destinationFolderURL = preferredRipDestinationFolder()

        let metadata = metadataForPlaylistEntry(item.entry, sourceVideoURL: videoURL)

        Task {
            do {
                let crate = try resolveOrCreateTargetCrate()
                let rootDirectory = libraryService.rootDirectory
                let databaseFileURL = libraryService.databaseFile

                try FileManager.default.createDirectory(
                    at: destinationFolderURL,
                    withIntermediateDirectories: true
                )

                let outputFileURL = try await Task.detached(priority: .userInitiated) {
                    let download = try YouTubeAudioImportService.downloadAudio(
                        .init(
                            videoURL: videoURL,
                            destinationFolderURL: destinationFolderURL,
                            audioFormat: .mp3,
                            audioQuality: .high,
                            audioBitrateKbps: 320,
                            metadata: metadata
                        )
                    )

                    try writeDownloadedTrackToSeratoDatabase(
                        fileURL: download.outputFileURL,
                        rootDirectory: rootDirectory,
                        databaseFileURL: databaseFileURL,
                        metadata: metadata
                    )

                    _ = try AddMusicImportService.appendAudioFiles(
                        [download.outputFileURL],
                        toExistingCrate: crate,
                        rootDirectory: rootDirectory
                    )

                    return download.outputFileURL
                }.value

                onLibraryChanged()
                refreshMatchAfterRip(removing: item)
                try? alignTargetCrateToCurrentSelectionOrder()
                planStatusByID[item.id] = "Downloaded \(outputFileURL.lastPathComponent) and added to crate."
                successMessage = "Downloaded \(outputFileURL.lastPathComponent) and added it to \(targetCrateName). Matched: \(matchedEntries.count), Plan: \(planItems.count)."
            } catch {
                errorMessage = error.localizedDescription
                planStatusByID[item.id] = "Failed: \(error.localizedDescription)"
            }

            rippingPlanIDs.remove(item.id)
        }
    }

    private func ripMatchedEntryFromYouTube(_ entry: PlaylistMatchService.PlaylistEntry, preferredURL: URL? = nil) {
        let selectedURL: URL?
        if let preferredURL {
            selectedURL = preferredURL
            matchedYoutubeURLByEntryID[entry.id] = preferredURL.absoluteString
        } else {
            let rawURL = matchedYoutubeURLByEntryID[entry.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            selectedURL = YouTubeBatchLinkImportService.parseVideoURLs(from: rawURL).first
        }

        guard let videoURL = selectedURL else {
            errorMessage = PlaylistMatchRipError.invalidYouTubeURL.localizedDescription
            return
        }

        let dependencyStatus = YouTubeAudioImportService.dependencyStatus()
        guard dependencyStatus.isReady else {
            errorMessage = PlaylistMatchRipError.dependenciesMissing.localizedDescription
            return
        }

        errorMessage = nil
        successMessage = nil
        matchedRippingEntryIDs.insert(entry.id)
        matchedStatusByEntryID[entry.id] = "Downloading from YouTube..."

        let destinationFolderURL = preferredRipDestinationFolder()
        let metadata = metadataForPlaylistEntry(entry, sourceVideoURL: videoURL)

        Task {
            do {
                let crate = try resolveOrCreateTargetCrate()
                let rootDirectory = libraryService.rootDirectory
                let databaseFileURL = libraryService.databaseFile

                try FileManager.default.createDirectory(
                    at: destinationFolderURL,
                    withIntermediateDirectories: true
                )

                let outputFileURL = try await Task.detached(priority: .userInitiated) {
                    let download = try YouTubeAudioImportService.downloadAudio(
                        .init(
                            videoURL: videoURL,
                            destinationFolderURL: destinationFolderURL,
                            audioFormat: .mp3,
                            audioQuality: .high,
                            audioBitrateKbps: 320,
                            metadata: metadata
                        )
                    )

                    try writeDownloadedTrackToSeratoDatabase(
                        fileURL: download.outputFileURL,
                        rootDirectory: rootDirectory,
                        databaseFileURL: databaseFileURL,
                        metadata: metadata
                    )

                    _ = try AddMusicImportService.appendAudioFiles(
                        [download.outputFileURL],
                        toExistingCrate: crate,
                        rootDirectory: rootDirectory
                    )

                    return download.outputFileURL
                }.value

                onLibraryChanged()
                refreshMatchAfterMatchedRip(entryID: entry.id, downloadedFileURL: outputFileURL)
                try? alignTargetCrateToCurrentSelectionOrder()
                matchedStatusByEntryID[entry.id] = "Downloaded \(outputFileURL.lastPathComponent) and added to crate."
                successMessage = "Downloaded \(outputFileURL.lastPathComponent) and added it to \(targetCrateName)."
            } catch {
                errorMessage = error.localizedDescription
                matchedStatusByEntryID[entry.id] = "Failed: \(error.localizedDescription)"
            }

            matchedRippingEntryIDs.remove(entry.id)
        }
    }

    private var targetCrateName: String {
        let trimmed = crateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "PlaylistMatch" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }

    private func versionLabel(for track: Track) -> String {
        let title = track.title.lowercased()
        if title.contains("extended") {
            return "Extended"
        }
        if title.contains("intro") {
            return "Intro"
        }
        if title.contains("instrumental") {
            return "Instrumental"
        }
        if title.contains("acapella") || title.contains("a cappella") {
            return "Acapella"
        }
        if title.contains("clean") {
            return "Clean"
        }
        if title.contains("dirty") {
            return "Dirty"
        }
        if title.contains("radio") {
            return "Radio"
        }
        if title.contains("edit") {
            return "Edit"
        }
        if title.contains("mix") {
            return "Mix"
        }
        return "Version"
    }

    private func resolveOrCreateTargetCrate() throws -> Crate {
        if let existing = libraryService.crates.first(where: { $0.name == targetCrateName }) {
            return existing
        }

        guard !matchedTracks.isEmpty else {
            throw PlaylistMatchRipError.targetCrateMissing
        }

        _ = try upsertTargetCrateFromCurrentSelection()
        onLibraryChanged()

        if let created = libraryService.crates.first(where: { $0.name == targetCrateName }) {
            return created
        }

        throw PlaylistMatchRipError.targetCrateMissing
    }

    private func refreshMatchAfterRip(removing item: PlaylistMatchService.PlanItem) {
        guard !resolvedEntries.isEmpty else {
            // Loaded plans can exist without source playlist context.
            planItems.removeAll { $0.id == item.id }
            youtubeURLByPlanID[item.id] = ""
            youtubeSuggestionsByPlanID[item.id] = nil
            return
        }

        do {
            let latestLibraryTracks = try SeratoDatabaseParser.parseTracks(
                at: libraryService.databaseFile,
                rootDirectory: libraryService.rootDirectory
            )
            let result = PlaylistMatchService.match(entries: resolvedEntries, libraryTracks: latestLibraryTracks)

            let previousSelection = selectedVersionByEntryID
            let previousMatchedIDs = Set(matchedEntries.map { $0.entry.id })
            let previousIncluded = includedMatchedEntryIDs
            matchedEntries = result.matchedEntries
            includedMatchedEntryIDs = Set(result.matchedEntries.compactMap { entry in
                if previousMatchedIDs.contains(entry.entry.id) {
                    return previousIncluded.contains(entry.entry.id) ? entry.entry.id : nil
                }
                return entry.entry.id
            })
            selectedVersionByEntryID = Dictionary(
                uniqueKeysWithValues: result.matchedEntries.map { entry in
                    let previous = previousSelection[entry.entry.id]
                    let selected = entry.versions.first(where: { $0.id == previous })?.id ?? entry.primaryTrack.id
                    return (entry.entry.id, selected)
                }
            )
            matchedTracks = selectedMatchedTracks(from: result.matchedEntries)
            planItems = result.planItems
            resolvedEntryCount = resolvedEntries.count

            let remainingPlanIDs = Set(result.planItems.map(\.id))
            youtubeURLByPlanID = Dictionary(uniqueKeysWithValues: result.planItems.map { plan in
                (plan.id, youtubeURLByPlanID[plan.id] ?? "")
            })
            planStatusByID = planStatusByID.filter { remainingPlanIDs.contains($0.key) }
            youtubeSuggestionsByPlanID = youtubeSuggestionsByPlanID.filter { remainingPlanIDs.contains($0.key) }
        } catch {
            // Keep the rip flow successful even if immediate re-parse fails.
            planItems.removeAll { $0.id == item.id }
            youtubeURLByPlanID[item.id] = ""
            youtubeSuggestionsByPlanID[item.id] = nil
        }
    }

    private func refreshMatchAfterMatchedRip(entryID: UUID, downloadedFileURL: URL) {
        guard !resolvedEntries.isEmpty else { return }

        do {
            let latestLibraryTracks = try SeratoDatabaseParser.parseTracks(
                at: libraryService.databaseFile,
                rootDirectory: libraryService.rootDirectory
            )
            let result = PlaylistMatchService.match(entries: resolvedEntries, libraryTracks: latestLibraryTracks)

            let previousSelection = selectedVersionByEntryID
            let previousMatchedIDs = Set(matchedEntries.map { $0.entry.id })
            let previousIncluded = includedMatchedEntryIDs
            matchedEntries = result.matchedEntries
            includedMatchedEntryIDs = Set(result.matchedEntries.compactMap { entry in
                if entry.entry.id == entryID {
                    return entry.entry.id
                }
                if previousMatchedIDs.contains(entry.entry.id) {
                    return previousIncluded.contains(entry.entry.id) ? entry.entry.id : nil
                }
                return entry.entry.id
            })
            selectedVersionByEntryID = Dictionary(
                uniqueKeysWithValues: result.matchedEntries.map { entry in
                    if entry.entry.id == entryID,
                       let downloaded = entry.versions.first(where: { pathsEquivalent($0.fileURL, downloadedFileURL) }) {
                        return (entry.entry.id, downloaded.id)
                    }

                    let previous = previousSelection[entry.entry.id]
                    let selected = entry.versions.first(where: { $0.id == previous })?.id ?? entry.primaryTrack.id
                    return (entry.entry.id, selected)
                }
            )
            matchedTracks = selectedMatchedTracks(from: result.matchedEntries)
            planItems = result.planItems
            resolvedEntryCount = resolvedEntries.count

            let remainingPlanIDs = Set(result.planItems.map(\.id))
            youtubeURLByPlanID = Dictionary(uniqueKeysWithValues: result.planItems.map { plan in
                (plan.id, youtubeURLByPlanID[plan.id] ?? "")
            })
            planStatusByID = planStatusByID.filter { remainingPlanIDs.contains($0.key) }
            youtubeSuggestionsByPlanID = youtubeSuggestionsByPlanID.filter { remainingPlanIDs.contains($0.key) }
        } catch {
            matchedStatusByEntryID[entryID] = "Added track, but refresh failed: \(error.localizedDescription)"
        }
    }

    private func metadataForPlaylistEntry(_ entry: PlaylistMatchService.PlaylistEntry, sourceVideoURL: URL) -> SeratoTrackMetadataUpdate {
        SeratoTrackMetadataUpdate(
            title: entry.title,
            artist: entry.artist,
            album: "",
            genre: "",
            comment: sourceVideoURL.absoluteString,
            key: "",
            bpm: nil,
            year: nil
        )
    }

    private func pathsEquivalent(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ fileURL: URL) -> String {
        var path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    private func cacheCurrentState() {
        PlaylistMatchInMemoryCache.state = CachedState(
            rawInput: rawInput,
            crateName: crateName,
            detectedPlaylistName: detectedPlaylistName,
            parserDiagnostics: parserDiagnostics,
            successMessage: successMessage,
            errorMessage: errorMessage,
            resolvedEntries: resolvedEntries,
            matchedEntries: matchedEntries,
            includedMatchedEntryIDs: includedMatchedEntryIDs,
            selectedVersionByEntryID: selectedVersionByEntryID,
            bulkVersionPreference: bulkVersionPreference,
            showOnlyUncheckedMatches: showOnlyUncheckedMatches,
            matchedTracks: matchedTracks,
            planItems: planItems,
            resolvedEntryCount: resolvedEntryCount,
            youtubeURLByPlanID: youtubeURLByPlanID,
            planStatusByID: planStatusByID,
            youtubeSuggestionsByPlanID: youtubeSuggestionsByPlanID,
            matchedYoutubeURLByEntryID: matchedYoutubeURLByEntryID,
            matchedStatusByEntryID: matchedStatusByEntryID,
            matchedSuggestionsByEntryID: matchedSuggestionsByEntryID
        )
    }

    private func restoreCachedStateIfNeeded() {
        guard let cached = PlaylistMatchInMemoryCache.state else { return }

        rawInput = cached.rawInput
        crateName = cached.crateName
        detectedPlaylistName = cached.detectedPlaylistName
        parserDiagnostics = cached.parserDiagnostics
        successMessage = cached.successMessage
        errorMessage = cached.errorMessage
        resolvedEntries = cached.resolvedEntries
        matchedEntries = cached.matchedEntries
        includedMatchedEntryIDs = cached.includedMatchedEntryIDs
        selectedVersionByEntryID = cached.selectedVersionByEntryID
        bulkVersionPreference = cached.bulkVersionPreference
        showOnlyUncheckedMatches = cached.showOnlyUncheckedMatches
        matchedTracks = cached.matchedTracks
        planItems = cached.planItems
        resolvedEntryCount = cached.resolvedEntryCount
        youtubeURLByPlanID = cached.youtubeURLByPlanID
        planStatusByID = cached.planStatusByID
        youtubeSuggestionsByPlanID = cached.youtubeSuggestionsByPlanID
        matchedYoutubeURLByEntryID = cached.matchedYoutubeURLByEntryID
        matchedStatusByEntryID = cached.matchedStatusByEntryID
        matchedSuggestionsByEntryID = cached.matchedSuggestionsByEntryID
    }

    private func upsertTargetCrateFromCurrentSelection() throws -> URL {
        let orderedSelectedPaths = orderedSelectedStoredPaths()
        guard !orderedSelectedPaths.isEmpty else {
            throw PlaylistMatchService.MatchError.noMatchedTracks
        }

        if let existing = libraryService.crates.first(where: { $0.name == targetCrateName }),
           existing.fileURL?.pathExtension.lowercased() == "crate" {
            let mergedPaths = mergedCratePathsPreservingPlaylistOrder(
                existing: existing.trackPaths,
                orderedSelected: orderedSelectedPaths
            )
            _ = try SeratoCrateEditor.rewriteTrackPaths(in: existing, to: mergedPaths)
            return existing.fileURL ?? crateFileURL(for: targetCrateName)
        }

        return try PlaylistMatchService.createCrateFromMatches(
            crateName: targetCrateName,
            matchedTracks: matchedTracks,
            subcratesDirectory: libraryService.subcratesDirectory
        )
    }

    private func alignTargetCrateToCurrentSelectionOrder() throws {
        let crateURL = crateFileURL(for: targetCrateName)
        guard FileManager.default.fileExists(atPath: crateURL.path) else { return }

        let parsed = try SeratoCrateParser.parseCrate(at: crateURL)
        let orderedSelectedPaths = orderedSelectedStoredPaths()
        guard !orderedSelectedPaths.isEmpty else { return }

        let mergedPaths = mergedCratePathsPreservingPlaylistOrder(
            existing: parsed.trackPaths,
            orderedSelected: orderedSelectedPaths
        )

        _ = try SeratoCrateEditor.rewriteTrackPaths(in: parsed, to: mergedPaths)
    }

    private func orderedSelectedStoredPaths() -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        for entry in matchedEntries {
            guard includedMatchedEntryIDs.contains(entry.entry.id) else { continue }
            let selectedTrackID = selectedVersionByEntryID[entry.entry.id] ?? entry.primaryTrack.id
            let selectedTrack = entry.versions.first(where: { $0.id == selectedTrackID }) ?? entry.primaryTrack
            if seen.insert(selectedTrack.seratoStoredPath).inserted {
                output.append(selectedTrack.seratoStoredPath)
            }
        }

        return output
    }

    private func mergedCratePathsPreservingPlaylistOrder(existing: [String], orderedSelected: [String]) -> [String] {
        let selectedSet = Set(orderedSelected)
        let existingRemainder = existing.filter { !selectedSet.contains($0) }
        return uniquePreservingOrder(orderedSelected + existingRemainder)
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    private func crateFileURL(for crateName: String) -> URL {
        libraryService.subcratesDirectory
            .appendingPathComponent(crateName)
            .appendingPathExtension("crate")
    }
}

private extension PlaylistMatchView {
    func preferredRipDestinationFolder() -> URL {
        let root = libraryService.rootDirectory.standardizedFileURL
        if root.path == "/" {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
        }
        return root.appendingPathComponent("Music", isDirectory: true)
    }
}

private struct CachedState {
    let rawInput: String
    let crateName: String
    let detectedPlaylistName: String?
    let parserDiagnostics: PlaylistMatchService.ParserDiagnostics?
    let successMessage: String?
    let errorMessage: String?
    let resolvedEntries: [PlaylistMatchService.PlaylistEntry]
    let matchedEntries: [PlaylistMatchService.MatchedEntry]
    let includedMatchedEntryIDs: Set<UUID>
    let selectedVersionByEntryID: [UUID: UUID]
    let bulkVersionPreference: PlaylistMatchView.BulkVersionPreference
    let showOnlyUncheckedMatches: Bool
    let matchedTracks: [Track]
    let planItems: [PlaylistMatchService.PlanItem]
    let resolvedEntryCount: Int
    let youtubeURLByPlanID: [UUID: String]
    let planStatusByID: [UUID: String]
    let youtubeSuggestionsByPlanID: [UUID: [YouTubeAudioImportService.SearchResult]]
    let matchedYoutubeURLByEntryID: [UUID: String]
    let matchedStatusByEntryID: [UUID: String]
    let matchedSuggestionsByEntryID: [UUID: [YouTubeAudioImportService.SearchResult]]
}

@MainActor
private enum PlaylistMatchInMemoryCache {
    static var state: CachedState?
}

private func writeDownloadedTrackToSeratoDatabase(
    fileURL: URL,
    rootDirectory: URL,
    databaseFileURL: URL,
    metadata: SeratoTrackMetadataUpdate
) throws {
    if FileManager.default.fileExists(atPath: databaseFileURL.path) {
        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
    }

    let original = try Data(contentsOf: databaseFileURL)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)

    let ensured = SeratoDatabaseWriter.ensuringTrackExists(
        forStoredPath: storedPath,
        metadata: metadata,
        in: original
    )

    let rewritten = SeratoDatabaseWriter.rewritingMetadata(
        forStoredPath: storedPath,
        metadata: metadata,
        in: ensured.data
    )

    if ensured.didInsert || rewritten.didRewrite {
        try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)
    }
}

private enum PlaylistMatchRipError: LocalizedError {
    case dependenciesMissing
    case invalidYouTubeURL
    case targetCrateMissing

    var errorDescription: String? {
        switch self {
        case .dependenciesMissing:
            return "yt-dlp and ffmpeg are required before ripping from YouTube."
        case .invalidYouTubeURL:
            return "Paste a valid YouTube URL for this Plan item first."
        case .targetCrateMissing:
            return "Create your PlaylistMatch crate from matched tracks before adding ripped Plan items."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .dependenciesMissing:
            return "Install yt-dlp and ffmpeg, then try Rip + Add again."
        case .invalidYouTubeURL:
            return "Use a full youtube.com or youtu.be link."
        case .targetCrateMissing:
            return "Click Create Crate From Matches, then retry the Plan item rip."
        }
    }
}