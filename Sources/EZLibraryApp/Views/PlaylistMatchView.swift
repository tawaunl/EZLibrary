import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EZLibraryCore

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
    @State private var warningMessage: String?
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
    @State private var matchedYoutubeURLByEntryID: [UUID: String] = [:]
    @State private var matchedStatusByEntryID: [UUID: String] = [:]
    @State private var matchedSearchingEntryIDs: Set<UUID> = []
    @State private var matchedRippingEntryIDs: Set<UUID> = []
    @State private var matchedSuggestionsByEntryID: [UUID: [YouTubeAudioImportService.SearchResult]] = [:]

    @State private var purchaseLinksByEntryID: [UUID: [PurchaseLinkService.PurchaseLink]] = [:]
    @State private var loadingPurchaseLinkEntryIDs: Set<UUID> = []
    @State private var recordPoolResultsByEntryID: [UUID: [RecordPoolResult]] = [:]
    @State private var loadingRecordPoolEntryIDs: Set<UUID> = []
    @State private var configuredRecordPools: [RecordPool] = []
    @State private var showRecordPoolCredentials = false
    private let recordPoolCredentialStore = RecordPoolCredentialStore()
    @State private var importingPlanIDs: Set<UUID> = []
    @State private var importingEntryIDs: Set<UUID> = []
    @State private var expandedDownloadPlanIDs: Set<UUID> = []
    @State private var expandedDownloadEntryIDs: Set<UUID> = []
    @StateObject private var downloadsWatcher = DownloadsFolderWatcher()
    @State private var detectedDownloadMatches: [DownloadMatch] = []
    @State private var downloadTagCache: [URL: AudioFileTagReader.Tags] = [:]
    @AppStorage(SeratoFeatureFlags.mainMusicFolderDefaultsKey) private var centralMusicFolderPath = ""

    struct DownloadMatch: Identifiable, Hashable {
        let url: URL
        let item: PlaylistMatchService.PlanItem
        var id: URL { url }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeaderCard(
                    title: "PlaylistMatch",
                    description: "Paste a single Spotify or Apple Music playlist link (or upload a CSV). PlaylistMatch scans your Serato library, builds a crate from matches, and keeps unmatched tracks in a Plan.",
                    icon: "music.quarternote.3"
                )

                inputCard
                summaryCard
                detectedDownloadsCard
                planCard
            }
            .padding(16)
        }
        .onAppear {
            restoreCachedStateIfNeeded()
            refreshConfiguredRecordPools()
            downloadsWatcher.start()
        }
        .onDisappear {
            cacheCurrentState()
            downloadsWatcher.stop()
        }
        .onChange(of: downloadsWatcher.detectedFiles) {
            processDetectedDownloads()
        }
        .onChange(of: planItems) {
            processDetectedDownloads()
        }
        .sheet(isPresented: $showRecordPoolCredentials) {
            RecordPoolCredentialsSheet(onCredentialsChanged: {
                refreshConfiguredRecordPools()
                recordPoolResultsByEntryID = [:]
                loadingRecordPoolEntryIDs = []
            })
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Playlist Link")
                .font(.title3.weight(.semibold))

            TextField("https://open.spotify.com/playlist/… or Apple Music link", text: $rawInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .onSubmit { runMatch() }

            Text("Paste one Spotify or Apple Music playlist link at a time, then Scan Playlist. Use Upload CSV to match a Title/Artist file instead. Up to \(PlaylistMatchService.maxPlaylistEntries) tracks are matched per run.")
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
                .help("Read the pasted playlist and match its tracks against your Serato library.")

                Button("Upload CSV") {
                    importCSVFile()
                }
                .disabled(isRunning)
                .help("Choose a .csv file with Title/Artist columns and match it against your library.")

                Button("Clear") {
                    clearResults()
                }
                .disabled(isRunning)
                .help("Clear the input and all match results.")

                Button("Save Plan") {
                    savePlanToDisk()
                }
                .disabled(planItems.isEmpty || isRunning)
                .help("Save the unmatched tracks to a plan file you can reload later.")

                Button("Load Plan") {
                    loadPlanFromDisk()
                }
                .disabled(isRunning)
                .help("Load a previously saved plan of unmatched tracks.")

                Button(configuredRecordPools.isEmpty ? "Record Pools…" : "Record Pools (\(configuredRecordPools.count))") {
                    showRecordPoolCredentials = true
                }
                .help("Sign in to DJ record pools (BPM Supreme, DJcity) to search them in-app for tracks you can't buy.")

                Spacer(minLength: 0)
            }

            if let successMessage {
                Text(successMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            }

            if let warningMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(warningMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)

                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .overlay(alignment: .topTrailing) {
                            FastHoverHelp(
                                text: "In Spotify: open the mix → … → Add to other playlist → New Playlist, then paste the new playlist's link here."
                            )
                            .offset(x: 2, y: -2)
                        }
                }
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
            .help("Build a new Serato crate from the selected matched tracks.")

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
                .help("Apply the selected version preference to every matched track.")

                Button("Select All") {
                    includedMatchedEntryIDs = Set(matchedEntries.map { $0.entry.id })
                    matchedTracks = selectedMatchedTracks(from: matchedEntries)
                }
                .disabled(matchedEntries.isEmpty)
                .help("Include every matched track in the crate.")

                Button("Select None") {
                    includedMatchedEntryIDs.removeAll()
                    matchedTracks = []
                }
                .disabled(matchedEntries.isEmpty)
                .help("Exclude all matched tracks from the crate.")

                Spacer(minLength: 0)
            }

            if !matchedEntries.isEmpty {
                let visibleEntries = matchedEntries.filter { includedMatchedEntryIDs.contains($0.entry.id) }

                if visibleEntries.isEmpty {
                    Text("No matched songs are included. Unchecked matches move to the Plan below — re-include them there anytime.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
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

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Other versions to buy:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                purchaseLinksSection(
                                    links: purchaseLinksByEntryID[item.entry.id],
                                    isLoading: loadingPurchaseLinkEntryIDs.contains(item.entry.id)
                                )
                                .onAppear { findPurchaseLinks(forEntry: item.entry) }

                                HStack(spacing: 8) {
                                    Button {
                                        importPurchasedFileForMatched(item.entry)
                                    } label: {
                                        Label(
                                            importingEntryIDs.contains(item.entry.id) ? "Importing…" : "I Bought It — Import File…",
                                            systemImage: "square.and.arrow.down"
                                        )
                                    }
                                    .controlSize(.small)
                                    .disabled(importingEntryIDs.contains(item.entry.id))
                                    .help("Pick a version you bought to add it to \(targetCrateName).")

                                    Spacer(minLength: 0)
                                }

                                if let status = matchedStatusByEntryID[item.entry.id] {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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
    /// Re-evaluates detected downloads against the current Plan, using the
    /// filename first and the file's ID3/metadata tags as a fallback. Reads run
    /// off the main actor and results are cached per file.
    private func processDetectedDownloads() {
        let files = downloadsWatcher.detectedFiles
        guard !files.isEmpty, !planItems.isEmpty else {
            detectedDownloadMatches = []
            return
        }

        let entries = planItems.map(\.entry)
        let items = planItems

        Task {
            var matches: [DownloadMatch] = []
            for url in files {
                let tags: AudioFileTagReader.Tags
                if let cached = downloadTagCache[url] {
                    tags = cached
                } else {
                    tags = await AudioFileTagReader.readTags(from: url)
                    downloadTagCache[url] = tags
                }

                if let entry = PlaylistMatchService.matchDownloadedTrack(
                        filename: url.lastPathComponent,
                        tagTitle: tags.title,
                        tagArtist: tags.artist,
                        entries: entries
                   ),
                   let item = items.first(where: { $0.entry.id == entry.id }) {
                    matches.append(DownloadMatch(url: url, item: item))
                }
            }
            detectedDownloadMatches = matches
        }
    }

    @ViewBuilder
    private var detectedDownloadsCard: some View {
        if !detectedDownloadMatches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("New downloads detected", systemImage: "arrow.down.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)

                Text("These files just landed in your Downloads folder and match a Plan track. Import them into \(targetCrateName) (they'll be moved to your central music folder).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(detectedDownloadMatches) { pair in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.url.lastPathComponent)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("Matches: \(pair.item.entry.artist.isEmpty ? "Unknown Artist" : pair.item.entry.artist) - \(pair.item.entry.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Button(importingPlanIDs.contains(pair.item.id) ? "Importing…" : "Import") {
                            importPurchasedFileForPlan(pair.item, fileURL: pair.url)
                            downloadsWatcher.dismiss(pair.url)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(importingPlanIDs.contains(pair.item.id))
                        .help("Add \(pair.url.lastPathComponent) to \(targetCrateName) and clear this Plan gap.")

                        Button("Dismiss") {
                            downloadsWatcher.dismiss(pair.url)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
                    )
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.35), lineWidth: 1))
        }
    }

    private var planCard: some View {
        let excludedMatches = matchedEntries.filter { !includedMatchedEntryIDs.contains($0.entry.id) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Plan")
                .font(.title3.weight(.semibold))
            if planItems.isEmpty && excludedMatches.isEmpty {
                Text("No gaps found. Your matched crate can be created as-is.")
                    .foregroundStyle(.secondary)
            } else {
                if !excludedMatches.isEmpty {
                    Text("Excluded matches — you have these in your library but left them out. Re-include to add them back to Matched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(excludedMatches) { item in
                            excludedMatchRow(for: item)
                        }
                    }
                }

                if !planItems.isEmpty {
                    Text("Tracks PlaylistMatch couldn't find in your library:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Buy the track first — we check iTunes and Beatport and only show a store when it actually has the song. Fall back to a YouTube rip only if you can't purchase it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(planItems) { item in
                    let artist = item.entry.artist.isEmpty ? "Unknown Artist" : item.entry.artist
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• \(artist) - \(item.entry.title)")
                            .font(.callout.weight(.semibold))

                        purchaseLinksSection(
                            links: purchaseLinksByEntryID[item.entry.id],
                            isLoading: loadingPurchaseLinkEntryIDs.contains(item.entry.id)
                        )
                        .onAppear { findPurchaseLinks(forEntry: item.entry) }

                        HStack(spacing: 8) {
                            Button {
                                importPurchasedFileForPlan(item)
                            } label: {
                                Label(
                                    importingPlanIDs.contains(item.id) ? "Importing…" : "I Bought It — Import File…",
                                    systemImage: "square.and.arrow.down"
                                )
                            }
                            .controlSize(.small)
                            .disabled(importingPlanIDs.contains(item.id))
                            .help("Pick the audio file you just purchased to add it to \(targetCrateName).")

                            Spacer(minLength: 0)
                        }

                        if let status = planStatusByID[item.id] {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        DisclosureGroupRow(
                            title: "Can't Download it?",
                            isExpanded: expandedDownloadPlanIDs.contains(item.id),
                            toggle: {
                                if expandedDownloadPlanIDs.contains(item.id) {
                                    expandedDownloadPlanIDs.remove(item.id)
                                } else {
                                    expandedDownloadPlanIDs.insert(item.id)
                                }
                            }
                        ) {
                            youtubePlanControls(for: item)
                                .padding(.top, 6)
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
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    /// A matched song the user unchecked: it lives in the Plan so they can act
    /// on it, but the match stays persistent — "Add back to Matched" re-includes
    /// it (and its selected version) in the crate.
    @ViewBuilder
    private func excludedMatchRow(for item: PlaylistMatchService.MatchedEntry) -> some View {
        let artist = item.entry.artist.isEmpty ? "Unknown Artist" : item.entry.artist
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("• \(artist) - \(item.entry.title)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("In your library: \(item.primaryTrack.title.isEmpty ? item.primaryTrack.fileURL.lastPathComponent : item.primaryTrack.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    includedMatchedEntryIDs.insert(item.entry.id)
                    matchedTracks = selectedMatchedTracks(from: matchedEntries)
                } label: {
                    Label("Add back to Matched", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Re-include this match so it's added to the crate again.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Other versions to buy:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                purchaseLinksSection(
                    links: purchaseLinksByEntryID[item.entry.id],
                    isLoading: loadingPurchaseLinkEntryIDs.contains(item.entry.id)
                )
                .onAppear { findPurchaseLinks(forEntry: item.entry) }

                HStack(spacing: 8) {
                    Button {
                        importPurchasedFileForMatched(item.entry)
                    } label: {
                        Label(
                            importingEntryIDs.contains(item.entry.id) ? "Importing…" : "I Bought It — Import File…",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .controlSize(.small)
                    .disabled(importingEntryIDs.contains(item.entry.id))
                    .help("Pick a version you bought to add it to \(targetCrateName).")

                    Spacer(minLength: 0)
                }

                if let status = matchedStatusByEntryID[item.entry.id] {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroupRow(
                title: "Can't Download it?",
                isExpanded: expandedDownloadEntryIDs.contains(item.entry.id),
                toggle: {
                    if expandedDownloadEntryIDs.contains(item.entry.id) {
                        expandedDownloadEntryIDs.remove(item.entry.id)
                    } else {
                        expandedDownloadEntryIDs.insert(item.entry.id)
                    }
                }
            ) {
                youtubeMatchedControls(for: item.entry)
                    .padding(.top, 6)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func purchaseLinksSection(
        links: [PurchaseLinkService.PurchaseLink]?,
        isLoading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading, links == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding purchase links…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let links, !links.isEmpty {
                let grouped = Dictionary(grouping: links, by: { $0.store })
                let stores = PurchaseLinkService.Store.allCases.filter { grouped[$0]?.isEmpty == false }
                HStack(spacing: 8) {
                    Text("Buy:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(stores, id: \.self) { store in
                        purchaseStoreControl(store: store, links: grouped[store] ?? [])
                    }
                    Spacer(minLength: 0)
                }
            } else if let links, links.isEmpty, !isLoading {
                Text("Couldn't find this track for sale on iTunes or Beatport.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One control per store. When the store carries several versions
    /// (Extended, Radio Edit, Dirty, Intro, …) they collapse into a single
    /// menu so the user picks the version instead of seeing a box per version.
    @ViewBuilder
    private func purchaseStoreControl(
        store: PurchaseLinkService.Store,
        links: [PurchaseLinkService.PurchaseLink]
    ) -> some View {
        if links.count <= 1, let link = links.first {
            Button {
                NSWorkspace.shared.open(link.url)
            } label: {
                if let price = link.priceText, !price.isEmpty {
                    Label("Buy on \(store.displayName) — \(price)", systemImage: "cart")
                } else {
                    Label("Buy on \(store.displayName)", systemImage: "cart")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open \(store.displayName): \(purchaseMenuLabel(for: link))")
        } else {
            Menu {
                ForEach(links) { link in
                    Button(purchaseMenuLabel(for: link)) {
                        NSWorkspace.shared.open(link.url)
                    }
                }
            } label: {
                Label("Buy on \(store.displayName) (\(links.count))", systemImage: "cart")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Pick a version to buy on \(store.displayName).")
        }
    }

    private func purchaseMenuLabel(for link: PurchaseLinkService.PurchaseLink) -> String {
        if let price = link.priceText, !price.isEmpty {
            return "\(link.versionLabel) — \(price)"
        }
        return link.versionLabel
    }

    @ViewBuilder
    private func youtubePlanControls(for item: PlaylistMatchService.PlanItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    "Paste URL",
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
                .help("Search inside the app and list matching results below.")

                Button("Search URL") {
                    openDownloadSearch(for: item.entry)
                }
                .help("Open a search for this track on YouTube and SoundCloud in your browser.")

                Button(rippingPlanIDs.contains(item.id) ? "Downloading..." : "Download + Add") {
                    ripPlanItemFromYouTube(item)
                }
                .disabled(rippingPlanIDs.contains(item.id))
                .help("Download the audio from the pasted URL and add it to your library.")
            }

            if let suggestions = youtubeSuggestionsByPlanID[item.id], !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(suggestions) { suggestion in
                                SuggestionRow(
                                    suggestion: suggestion,
                                    isRipping: rippingPlanIDs.contains(item.id),
                                    onUseLink: {
                                        youtubeURLByPlanID[item.id] = suggestion.webpageURL.absoluteString
                                    },
                                    onUseAndDownload: {
                                        ripPlanItemFromYouTube(item, preferredURL: suggestion.webpageURL)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                )
            }
        }
    }

    @ViewBuilder
    private func youtubeMatchedControls(for entry: PlaylistMatchService.PlaylistEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    "Paste URL",
                    text: Binding(
                        get: { matchedYoutubeURLByEntryID[entry.id] ?? "" },
                        set: { matchedYoutubeURLByEntryID[entry.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Button(matchedSearchingEntryIDs.contains(entry.id) ? "Finding..." : "Find In-App") {
                    searchYouTubeSuggestions(for: entry)
                }
                .disabled(matchedSearchingEntryIDs.contains(entry.id))
                .help("Search inside the app and list matching results below.")

                Button("Search URL") {
                    openDownloadSearch(for: entry)
                }
                .help("Open a search for this track on YouTube and SoundCloud in your browser.")

                Button(matchedRippingEntryIDs.contains(entry.id) ? "Downloading..." : "Download + Add") {
                    ripMatchedEntryFromYouTube(entry)
                }
                .disabled(matchedRippingEntryIDs.contains(entry.id))
                .help("Download the audio from the pasted URL and add it to your library.")
            }

            if let suggestions = matchedSuggestionsByEntryID[entry.id], !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(suggestions) { suggestion in
                                SuggestionRow(
                                    suggestion: suggestion,
                                    isRipping: matchedRippingEntryIDs.contains(entry.id),
                                    onUseLink: {
                                        matchedYoutubeURLByEntryID[entry.id] = suggestion.webpageURL.absoluteString
                                    },
                                    onUseAndDownload: {
                                        ripMatchedEntryFromYouTube(entry, preferredURL: suggestion.webpageURL)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                )
            }
        }
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
        rawInput = ""
        crateName = "PlaylistMatch"
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
        matchedYoutubeURLByEntryID = [:]
        matchedStatusByEntryID = [:]
        matchedSearchingEntryIDs = []
        matchedRippingEntryIDs = []
        matchedSuggestionsByEntryID = [:]
        purchaseLinksByEntryID = [:]
        loadingPurchaseLinkEntryIDs = []
        successMessage = nil
        warningMessage = nil
        errorMessage = nil
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
        warningMessage = nil
        errorMessage = nil

        let input = rawInput
        let libraryTracks = libraryService.tracks

        Task {
            do {
                let resolved = try await PlaylistMatchService.resolvePlaylist(from: input)
                // Matching normalizes/compares against the whole library —
                // run it off the main actor so the UI doesn't freeze.
                let entries = resolved.entries
                let result = await Task.detached(priority: .userInitiated) {
                    PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)
                }.value
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
                var message = "Matched \(result.matchedEntries.count) songs. Added \(result.planItems.count) to Plan."
                if resolved.totalEntriesFound > resolved.entries.count {
                    message += " Source had \(resolved.totalEntriesFound) tracks; limited to the first \(PlaylistMatchService.maxPlaylistEntries)."
                }
                successMessage = message
                warningMessage = PlaylistMatchService.spotifyPersonalizedMixNote(for: input)
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

    private func importCSVFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Upload CSV"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            let contents = try readTextFile(at: selectedURL)
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                errorMessage = "\(selectedURL.lastPathComponent) is empty."
                return
            }
            rawInput = contents
            errorMessage = nil
            successMessage = "Loaded \(selectedURL.lastPathComponent). Scanning…"
            runMatch()
        } catch {
            errorMessage = "Couldn't read \(selectedURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Reads a CSV/text file, tolerating non-UTF-8 encodings some exporters
    /// (e.g. Excel) produce by falling back to Latin-1.
    private func readTextFile(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
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

    /// Accepts a pasted YouTube or SoundCloud URL (yt-dlp downloads from both).
    private func parseDownloadableURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = (trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"))
            ? trimmed
            : "https://\(trimmed)"

        guard
            let url = URL(string: withScheme),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(),
            host.contains("youtube.com") || host.contains("youtu.be") || host.contains("soundcloud.com")
        else {
            return nil
        }

        return url
    }

    private func openDownloadSearch(for entry: PlaylistMatchService.PlaylistEntry) {
        let query = [entry.artist, entry.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else { return }

        // Search both YouTube and SoundCloud — yt-dlp can download from either.
        if var youtube = URLComponents(string: "https://www.youtube.com/results") {
            youtube.queryItems = [URLQueryItem(name: "search_query", value: query)]
            if let url = youtube.url {
                NSWorkspace.shared.open(url)
            }
        }

        if var soundcloud = URLComponents(string: "https://soundcloud.com/search") {
            soundcloud.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = soundcloud.url {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Imports a file the user purchased from a store into the target crate:
    /// moves it into the central music folder (the consolidation destination),
    /// registers it in the Serato database, appends it to the crate, then
    /// re-matches to clear the gap.
    private func importPurchasedFileForPlan(_ item: PlaylistMatchService.PlanItem, fileURL: URL? = nil) {
        guard let selectedURL = fileURL ?? chooseAudioFileFromDownloads() else { return }

        errorMessage = nil
        successMessage = nil
        importingPlanIDs.insert(item.id)
        planStatusByID[item.id] = "Importing \(selectedURL.lastPathComponent)…"

        let metadata = metadataForPurchasedFile(item.entry)
        let destinationFolderURL = centralImportDestinationFolder

        Task {
            do {
                let crate = try resolveOrCreateTargetCrate()
                let rootDirectory = libraryService.rootDirectory
                let databaseFileURL = libraryService.databaseFile

                let importedURL = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let importResult = try AddMusicImportService.importAudioFiles(
                        inputURLs: [selectedURL],
                        destinationFolderURL: destinationFolderURL,
                        transferMode: .move
                    )
                    guard let importedURL = importResult.importedFileURLs.first else {
                        throw AddMusicImportService.ImportError.noSupportedAudioFiles
                    }

                    try writeDownloadedTrackToSeratoDatabase(
                        fileURL: importedURL,
                        rootDirectory: rootDirectory,
                        databaseFileURL: databaseFileURL,
                        metadata: metadata
                    )

                    _ = try AddMusicImportService.appendAudioFiles(
                        [importedURL],
                        toExistingCrate: crate,
                        rootDirectory: rootDirectory
                    )

                    return importedURL
                }.value

                onLibraryChanged()
                await refreshMatchAfterRip(removing: item)
                try? alignTargetCrateToCurrentSelectionOrder()
                planStatusByID[item.id] = "Imported \(importedURL.lastPathComponent) into \(targetCrateName)."
                successMessage = "Imported \(importedURL.lastPathComponent) into \(targetCrateName). Matched: \(matchedEntries.count), Plan: \(planItems.count)."
            } catch {
                errorMessage = error.localizedDescription
                planStatusByID[item.id] = "Import failed: \(error.localizedDescription)"
            }

            importingPlanIDs.remove(item.id)
        }
    }

    /// Imports a purchased file for a matched song: adds the bought version to
    /// the crate + Serato database and re-matches so it shows up as a version.
    private func importPurchasedFileForMatched(_ entry: PlaylistMatchService.PlaylistEntry, fileURL: URL? = nil) {
        guard let selectedURL = fileURL ?? chooseAudioFileFromDownloads() else { return }

        errorMessage = nil
        successMessage = nil
        importingEntryIDs.insert(entry.id)
        matchedStatusByEntryID[entry.id] = "Importing \(selectedURL.lastPathComponent)…"

        let metadata = metadataForPurchasedFile(entry)
        let destinationFolderURL = centralImportDestinationFolder

        Task {
            do {
                let crate = try resolveOrCreateTargetCrate()
                let rootDirectory = libraryService.rootDirectory
                let databaseFileURL = libraryService.databaseFile

                let importedURL = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let importResult = try AddMusicImportService.importAudioFiles(
                        inputURLs: [selectedURL],
                        destinationFolderURL: destinationFolderURL,
                        transferMode: .move
                    )
                    guard let importedURL = importResult.importedFileURLs.first else {
                        throw AddMusicImportService.ImportError.noSupportedAudioFiles
                    }

                    try writeDownloadedTrackToSeratoDatabase(
                        fileURL: importedURL,
                        rootDirectory: rootDirectory,
                        databaseFileURL: databaseFileURL,
                        metadata: metadata
                    )

                    _ = try AddMusicImportService.appendAudioFiles(
                        [importedURL],
                        toExistingCrate: crate,
                        rootDirectory: rootDirectory
                    )

                    return importedURL
                }.value

                onLibraryChanged()
                await refreshMatchAfterMatchedRip(entryID: entry.id, downloadedFileURL: importedURL)
                try? alignTargetCrateToCurrentSelectionOrder()
                matchedStatusByEntryID[entry.id] = "Imported \(importedURL.lastPathComponent) into \(targetCrateName)."
                successMessage = "Imported \(importedURL.lastPathComponent) into \(targetCrateName)."
            } catch {
                errorMessage = error.localizedDescription
                matchedStatusByEntryID[entry.id] = "Import failed: \(error.localizedDescription)"
            }

            importingEntryIDs.remove(entry.id)
        }
    }

    private func metadataForPurchasedFile(_ entry: PlaylistMatchService.PlaylistEntry) -> SeratoTrackMetadataUpdate {
        SeratoTrackMetadataUpdate(
            title: entry.title,
            artist: entry.artist,
            album: "",
            genre: "",
            comment: "",
            key: "",
            bpm: nil,
            year: nil
        )
    }

    /// Where imported/downloaded files land: the central music folder set on the
    /// home page (same setting the library was consolidated into). Falls back to
    /// the library's Music folder when that hasn't been configured yet.
    private var centralImportDestinationFolder: URL {
        let trimmed = centralMusicFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return preferredRipDestinationFolder()
    }

    private func chooseAudioFileFromDownloads() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the file you purchased"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let audioTypes = AddMusicImportService.supportedAudioExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = audioTypes.isEmpty ? [UTType.audio] : audioTypes + [UTType.audio]

        return panel.runModal() == .OK ? panel.url : nil
    }

    private func findPurchaseLinks(forEntry entry: PlaylistMatchService.PlaylistEntry) {
        // Auto-triggered on appear — only run once per entry. Keyed by the
        // stable entry.id (not the ephemeral PlanItem.id) so re-matches after
        // an import/rip reuse cached results instead of re-hitting the network.
        guard purchaseLinksByEntryID[entry.id] == nil, !loadingPurchaseLinkEntryIDs.contains(entry.id) else { return }

        guard !PurchaseLinkService.searchQuery(title: entry.title, artist: entry.artist).isEmpty else {
            purchaseLinksByEntryID[entry.id] = []
            return
        }

        loadingPurchaseLinkEntryIDs.insert(entry.id)

        Task {
            let links = await PurchaseLinkService.purchaseLinks(title: entry.title, artist: entry.artist)
            purchaseLinksByEntryID[entry.id] = links
            loadingPurchaseLinkEntryIDs.remove(entry.id)
        }
    }

    private func searchYouTubeSuggestions(for item: PlaylistMatchService.PlanItem) {
        let query = [item.entry.artist, PurchaseLinkService.coreTitle(item.entry.title)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else {
            planStatusByID[item.id] = "Missing title/artist for search query."
            return
        }

        searchingPlanIDs.insert(item.id)
        planStatusByID[item.id] = "Searching…"

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.searchAudioSuggestions(query: query, maxResults: 12)
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
        let query = [entry.artist, PurchaseLinkService.coreTitle(entry.title)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !query.isEmpty else {
            matchedStatusByEntryID[entry.id] = "Missing title/artist for search query."
            return
        }

        matchedSearchingEntryIDs.insert(entry.id)
        matchedStatusByEntryID[entry.id] = "Searching…"

        Task {
            do {
                let suggestions = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.searchAudioSuggestions(query: query, maxResults: 12)
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
            selectedURL = parseDownloadableURL(from: rawURL)
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
                await refreshMatchAfterRip(removing: item)
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
            selectedURL = parseDownloadableURL(from: rawURL)
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
                await refreshMatchAfterMatchedRip(entryID: entry.id, downloadedFileURL: outputFileURL)
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

    private func refreshMatchAfterRip(removing item: PlaylistMatchService.PlanItem) async {
        guard !resolvedEntries.isEmpty else {
            // Loaded plans can exist without source playlist context.
            planItems.removeAll { $0.id == item.id }
            youtubeURLByPlanID[item.id] = ""
            youtubeSuggestionsByPlanID[item.id] = nil
            return
        }

        do {
            // Re-parsing the whole database and re-matching every entry is
            // heavy — keep it off the main actor.
            let databaseFile = libraryService.databaseFile
            let rootDirectory = libraryService.rootDirectory
            let entries = resolvedEntries
            let result = try await Task.detached(priority: .userInitiated) {
                let latestLibraryTracks = try SeratoDatabaseParser.parseTracks(
                    at: databaseFile,
                    rootDirectory: rootDirectory
                )
                return PlaylistMatchService.match(entries: entries, libraryTracks: latestLibraryTracks)
            }.value

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

    private func refreshMatchAfterMatchedRip(entryID: UUID, downloadedFileURL: URL) async {
        guard !resolvedEntries.isEmpty else { return }

        do {
            // Same as `refreshMatchAfterRip`: full re-parse + re-match stays
            // off the main actor.
            let databaseFile = libraryService.databaseFile
            let rootDirectory = libraryService.rootDirectory
            let entries = resolvedEntries
            let result = try await Task.detached(priority: .userInitiated) {
                let latestLibraryTracks = try SeratoDatabaseParser.parseTracks(
                    at: databaseFile,
                    rootDirectory: rootDirectory
                )
                return PlaylistMatchService.match(entries: entries, libraryTracks: latestLibraryTracks)
            }.value

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
            matchedSuggestionsByEntryID: matchedSuggestionsByEntryID,
            purchaseLinksByEntryID: purchaseLinksByEntryID
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
        purchaseLinksByEntryID = cached.purchaseLinksByEntryID
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

/// Fully-clickable disclosure row: the whole title (not just the chevron)
/// toggles the section open/closed.
private struct DisclosureGroupRow<Content: View>: View {
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single in-app search suggestion (YouTube or SoundCloud). Extracted into
/// its own view so hover state stays local — hovering a row only re-renders
/// that row instead of the whole PlaylistMatch screen.
private struct SuggestionRow: View {
    let suggestion: YouTubeAudioImportService.SearchResult
    let isRipping: Bool
    let onUseLink: () -> Void
    let onUseAndDownload: () -> Void

    @State private var isHovered = false

    private var sourceName: String {
        let host = suggestion.webpageURL.host?.lowercased() ?? ""
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        return "Web"
    }

    private var sourceColor: Color {
        (suggestion.webpageURL.host?.lowercased().contains("soundcloud") ?? false)
            ? Color(red: 0.78, green: 0.52, blue: 0.32)
            : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(suggestion.title)
                        .font(.caption)
                        .lineLimit(1)

                    Button {
                        NSWorkspace.shared.open(suggestion.webpageURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open this result in your browser to check the exact link.")
                }

                HStack(spacing: 6) {
                    Text(sourceName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(sourceColor.opacity(0.18)))
                        .foregroundStyle(sourceColor)

                    Text(suggestion.channel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button("Use Link", action: onUseLink)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Use this suggestion's URL in the field above.")

                Button(isRipping ? "Downloading..." : "Use + Download", action: onUseAndDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRipping)
                    .help("Download this suggestion's audio and add it to your library.")
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
        .onHover { isHovered = $0 }
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
    let purchaseLinksByEntryID: [UUID: [PurchaseLinkService.PurchaseLink]]
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
            return "yt-dlp and ffmpeg are required before downloading audio."
        case .invalidYouTubeURL:
            return "Paste a valid YouTube or SoundCloud URL for this Plan item first."
        case .targetCrateMissing:
            return "Create your PlaylistMatch crate from matched tracks before adding downloaded Plan items."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .dependenciesMissing:
            return "Install yt-dlp and ffmpeg, then try Download + Add again."
        case .invalidYouTubeURL:
            return "Use a full youtube.com, youtu.be, or soundcloud.com link."
        case .targetCrateMissing:
            return "Click Create Crate From Matches, then retry the Plan item download."
        }
    }
}