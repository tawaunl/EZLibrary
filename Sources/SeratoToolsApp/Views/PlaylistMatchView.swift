import SwiftUI
import AppKit
import SeratoToolsCore

struct PlaylistMatchView: View {
    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var rawInput = ""
    @State private var crateName = "PlaylistMatch"
    @State private var isRunning = false
    @State private var isCreatingCrate = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var matchedTracks: [Track] = []
    @State private var planItems: [PlaylistMatchService.PlanItem] = []
    @State private var resolvedEntryCount = 0
    @State private var youtubeURLByPlanID: [UUID: String] = [:]
    @State private var rippingPlanIDs: Set<UUID> = []
    @State private var planStatusByID: [UUID: String] = [:]
    @State private var searchingPlanIDs: Set<UUID> = []
    @State private var youtubeSuggestionsByPlanID: [UUID: [YouTubeAudioImportService.SearchResult]] = [:]

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
                statTag(title: "Matched", value: "\(matchedTracks.count)", accent: true)
                statTag(title: "Plan", value: "\(planItems.count)")
                Spacer(minLength: 0)
            }

            Button(isCreatingCrate ? "Creating Crate..." : "Create Crate From Matches") {
                createCrateFromMatches()
            }
            .disabled(isCreatingCrate || matchedTracks.isEmpty)

            if !matchedTracks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(matchedTracks.prefix(20)), id: \.id) { track in
                        Text("• \(track.artist.isEmpty ? "Unknown Artist" : track.artist) - \(track.title.isEmpty ? track.fileURL.lastPathComponent : track.title)")
                            .font(.callout)
                            .lineLimit(1)
                    }

                    if matchedTracks.count > 20 {
                        Text("+ \(matchedTracks.count - 20) more matched tracks")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
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
                    .padding(.vertical, 6)
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
        resolvedEntryCount = 0
        matchedTracks = []
        planItems = []
        youtubeURLByPlanID = [:]
        rippingPlanIDs = []
        planStatusByID = [:]
        searchingPlanIDs = []
        youtubeSuggestionsByPlanID = [:]
        successMessage = nil
        errorMessage = nil
    }

    private func runMatch() {
        isRunning = true
        successMessage = nil
        errorMessage = nil

        let input = rawInput
        let libraryTracks = libraryService.tracks

        Task {
            do {
                let entries = try await PlaylistMatchService.resolveEntries(from: input)
                let result = PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)
                resolvedEntryCount = entries.count
                matchedTracks = result.matchedTracks
                planItems = result.planItems
                youtubeURLByPlanID = Dictionary(uniqueKeysWithValues: result.planItems.map { ($0.id, "") })
                planStatusByID = [:]
                youtubeSuggestionsByPlanID = [:]
                successMessage = "Matched \(result.matchedTracks.count) tracks. Added \(result.planItems.count) to Plan."
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
            let crateURL = try PlaylistMatchService.createCrateFromMatches(
                crateName: crateName,
                matchedTracks: matchedTracks,
                subcratesDirectory: libraryService.subcratesDirectory
            )
            onLibraryChanged()
            successMessage = "Created crate \(crateURL.deletingPathExtension().lastPathComponent) with \(matchedTracks.count) tracks."
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreatingCrate = false
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

        let destinationFolderURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)

        let metadata = SeratoTrackMetadataUpdate(
            title: item.entry.title,
            artist: item.entry.artist,
            album: "",
            genre: "",
            comment: videoURL.absoluteString,
            key: "",
            bpm: nil,
            year: nil
        )

        Task {
            do {
                let crate = try resolveOrCreateTargetCrate()
                let rootDirectory = libraryService.rootDirectory

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

                    _ = try AddMusicImportService.appendAudioFiles(
                        [download.outputFileURL],
                        toExistingCrate: crate,
                        rootDirectory: rootDirectory
                    )

                    return download.outputFileURL
                }.value

                onLibraryChanged()
                planItems.removeAll { $0.id == item.id }
                youtubeURLByPlanID[item.id] = ""
                planStatusByID[item.id] = "Downloaded \(outputFileURL.lastPathComponent) and added to crate."
                successMessage = "Downloaded \(outputFileURL.lastPathComponent) and added it to \(targetCrateName)."
            } catch {
                errorMessage = error.localizedDescription
                planStatusByID[item.id] = "Failed: \(error.localizedDescription)"
            }

            rippingPlanIDs.remove(item.id)
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

    private func resolveOrCreateTargetCrate() throws -> Crate {
        if let existing = libraryService.crates.first(where: { $0.name == targetCrateName }) {
            return existing
        }

        guard !matchedTracks.isEmpty else {
            throw PlaylistMatchRipError.targetCrateMissing
        }

        _ = try PlaylistMatchService.createCrateFromMatches(
            crateName: targetCrateName,
            matchedTracks: matchedTracks,
            subcratesDirectory: libraryService.subcratesDirectory
        )
        onLibraryChanged()

        if let created = libraryService.crates.first(where: { $0.name == targetCrateName }) {
            return created
        }

        throw PlaylistMatchRipError.targetCrateMissing
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