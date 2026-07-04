import SwiftUI
import AppKit
import SeratoToolsCore

struct YouTubeRipView: View {
    private static let formatDefaultsKey = "YouTubeRipSelectedFormat"
    private static let qualityDefaultsKey = "YouTubeRipSelectedQuality"
    private static let bitrateDefaultsKey = "YouTubeRipSelectedBitrate"
    private static let crateAssignmentDefaultsKey = "YouTubeRipCrateAssignment"
    private static let destinationDefaultsKey = "YouTubeRipDestinationPath"
    private static let cratePrefixDefaultsKey = "YouTubeRipCratePrefix"
    private static let autoLookupDefaultsKey = "YouTubeRipAutoLookupAfterLoad"

    private enum SeratoWriteOutcome {
        case inserted
        case updated
        case unchanged
    }

    private struct RecentDownload: Identifiable {
        let id = UUID()
        let title: String
        let fileName: String
        let crateLabel: String
        let downloadedAt: Date
    }

    private enum CrateAssignmentMode: String, CaseIterable, Identifiable {
        case dated
        case existing
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dated:
                return "Dated Crate"
            case .existing:
                return "Existing Crate"
            case .none:
                return "No Crate"
            }
        }
    }

    private enum BitrateSelection: String, CaseIterable, Identifiable {
        case auto
        case kbps128
        case kbps192
        case kbps256
        case kbps320

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto:
                return "Auto"
            case .kbps128:
                return "128 kbps"
            case .kbps192:
                return "192 kbps"
            case .kbps256:
                return "256 kbps"
            case .kbps320:
                return "320 kbps"
            }
        }

        var kbps: Int? {
            switch self {
            case .auto:
                return nil
            case .kbps128:
                return 128
            case .kbps192:
                return 192
            case .kbps256:
                return 256
            case .kbps320:
                return 320
            }
        }
    }

    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var urlText = ""
    @AppStorage(Self.destinationDefaultsKey) private var destinationPath = ""
    @AppStorage(Self.cratePrefixDefaultsKey) private var cratePrefix = "New Music"
    @AppStorage(Self.crateAssignmentDefaultsKey) private var crateAssignmentModeRaw = CrateAssignmentMode.dated.rawValue
    @State private var crateAssignmentMode: CrateAssignmentMode = .dated
    @State private var selectedExistingCrateID: UUID?
    @AppStorage(Self.formatDefaultsKey) private var selectedFormatRaw = YouTubeAudioImportService.AudioFormat.mp3.rawValue
    @AppStorage(Self.qualityDefaultsKey) private var selectedQualityRaw = YouTubeAudioImportService.AudioQuality.best.rawValue
    @AppStorage(Self.bitrateDefaultsKey) private var selectedBitrateRaw = BitrateSelection.kbps320.rawValue

    @State private var loadedInfo: YouTubeAudioImportService.VideoInfo?
    @State private var isLoadingInfo = false
    @State private var isDownloading = false
    @State private var dependencyStatusMessage: String?
    @State private var dependencyReady = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var lastSeratoWriteStatusMessage: String?
    @State private var recentDownloads: [RecentDownload] = []

    @State private var id3Title = ""
    @State private var id3Artist = ""
    @State private var id3Album = ""
    @State private var id3Genre = ""
    @State private var id3Comment = ""
    @State private var id3Key = ""
    @State private var id3BPM = ""
    @State private var id3Year = ""
    @AppStorage(Self.autoLookupDefaultsKey) private var autoLookupAfterLoadInfo = true
    @State private var lookupSourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .all
    @State private var isSearchingLookup = false
    @State private var lookupErrorMessage: String?
    @State private var lookupResults: [OnlineTrackMetadataCandidate] = []

    private var destinationFolderURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultDestinationFolderURL
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var defaultDestinationFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var downloadButtonTitle: String {
        if isDownloading {
            return "Downloading..."
        }
        return "Download + Create Dated Crate"
    }

    private var canDownload: Bool {
        !isDownloading && !isLoadingInfo && parsedVideoURL != nil && dependencyReady && isCrateSelectionValid
    }

    private var selectedFormat: YouTubeAudioImportService.AudioFormat {
        YouTubeAudioImportService.AudioFormat(rawValue: selectedFormatRaw) ?? .mp3
    }

    private var selectedQuality: YouTubeAudioImportService.AudioQuality {
        YouTubeAudioImportService.AudioQuality(rawValue: selectedQualityRaw) ?? .best
    }

    private var selectedBitrate: BitrateSelection {
        BitrateSelection(rawValue: selectedBitrateRaw) ?? .kbps320
    }

    private var selectedFormatBinding: Binding<YouTubeAudioImportService.AudioFormat> {
        Binding(get: { selectedFormat }, set: { selectedFormatRaw = $0.rawValue })
    }

    private var selectedQualityBinding: Binding<YouTubeAudioImportService.AudioQuality> {
        Binding(get: { selectedQuality }, set: { selectedQualityRaw = $0.rawValue })
    }

    private var selectedBitrateBinding: Binding<BitrateSelection> {
        Binding(get: { selectedBitrate }, set: { selectedBitrateRaw = $0.rawValue })
    }

    private var crateAssignmentModeBinding: Binding<CrateAssignmentMode> {
        Binding(get: { crateAssignmentMode }, set: { crateAssignmentMode = $0 })
    }

    private var supportsExplicitBitrate: Bool {
        formatSupportsExplicitBitrate(selectedFormat)
    }

    private var dependencyBadgeText: String {
        dependencyReady ? "Dependencies Ready" : "Dependencies Missing"
    }

    private var dependencyBadgeColor: Color {
        dependencyReady ? .green : .red
    }

    private var availableCrates: [Crate] {
        libraryService.crates.sorted {
            $0.pathComponents.joined(separator: " / ").localizedStandardCompare(
                $1.pathComponents.joined(separator: " / ")
            ) == .orderedAscending
        }
    }

    private var selectedExistingCrate: Crate? {
        guard let selectedExistingCrateID else { return nil }
        return availableCrates.first { $0.id == selectedExistingCrateID }
    }

    private var isCrateSelectionValid: Bool {
        switch crateAssignmentMode {
        case .dated, .none:
            return true
        case .existing:
            return selectedExistingCrate != nil
        }
    }

    private var parsedVideoURL: URL? {
        normalizeVideoURL(from: urlText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                urlCard
                if let loadedInfo {
                    videoPreviewCard(loadedInfo)
                }
                outputCard
                if selectedFormat == .mp3 {
                    id3Card
                }
                if !recentDownloads.isEmpty {
                    recentDownloadsCard
                }
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = defaultDestinationFolderURL.path
            }
            crateAssignmentMode = CrateAssignmentMode(rawValue: crateAssignmentModeRaw) ?? .dated
            checkDependencies()
        }
        .onChange(of: selectedFormat) {
            if !supportsExplicitBitrate {
                selectedBitrateRaw = BitrateSelection.auto.rawValue
            }
        }
        .onChange(of: crateAssignmentMode) {
            crateAssignmentModeRaw = crateAssignmentMode.rawValue
        }
        .onChange(of: crateAssignmentMode) {
            guard crateAssignmentMode == .existing else { return }
            if selectedExistingCrateID == nil {
                selectedExistingCrateID = availableCrates.first?.id
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YouTube Rip")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Paste a video link, preview artwork and info, choose format and quality, then download audio straight into your main music folder with a dated crate.")
                .foregroundStyle(.secondary)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video Link")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                TextField("https://www.youtube.com/watch?v=...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                Button("Load Info") {
                    loadVideoInfo()
                }
                .disabled(isLoadingInfo || parsedVideoURL == nil)
                Button("Check yt-dlp + ffmpeg") {
                    checkDependencies()
                }
                if isLoadingInfo {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let dependencyStatusMessage {
                Text(dependencyStatusMessage)
                    .font(.footnote)
                    .foregroundColor(dependencyReady ? .secondary : .red)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private func videoPreviewCard(_ info: YouTubeAudioImportService.VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let thumbnailURL = info.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Color.secondary.opacity(0.18)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        case .empty:
                            ProgressView()
                        @unknown default:
                            Color.secondary.opacity(0.18)
                        }
                    }
                } else {
                    Color.secondary.opacity(0.18)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 220, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.title3.weight(.semibold))
                if !info.uploader.isEmpty {
                    Text("Uploader: \(info.uploader)")
                        .foregroundStyle(.secondary)
                }
                if let durationSeconds = info.durationSeconds {
                    Text("Duration: \(formatDuration(durationSeconds))")
                        .foregroundStyle(.secondary)
                }
                if !info.uploadDate.isEmpty {
                    Text("Upload Date: \(formattedUploadDate(info.uploadDate))")
                        .foregroundStyle(.secondary)
                }
                if let webpageURL = info.webpageURL {
                    Text(webpageURL.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Picker("Format", selection: selectedFormatBinding) {
                    ForEach(YouTubeAudioImportService.AudioFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .frame(maxWidth: 180)

                Picker("Quality", selection: selectedQualityBinding) {
                    ForEach(YouTubeAudioImportService.AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .frame(maxWidth: 180)

                Spacer(minLength: 0)
            }

            if supportsExplicitBitrate {
                HStack(spacing: 10) {
                    Picker("Bitrate", selection: selectedBitrateBinding) {
                        ForEach(BitrateSelection.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .frame(maxWidth: 180)

                    Text("Applies to lossy formats only")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                TextField("Main music folder", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    chooseDestinationFolder()
                }
            }

            HStack(spacing: 10) {
                Text("Crate Prefix")
                    .foregroundStyle(.secondary)
                TextField("New Music", text: $cratePrefix)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Picker("Crate Assignment", selection: crateAssignmentModeBinding) {
                    ForEach(CrateAssignmentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(maxWidth: 220)

                Spacer(minLength: 0)
            }

            if crateAssignmentMode == .existing {
                HStack(spacing: 10) {
                    Picker(
                        "Existing Crate",
                        selection: Binding(
                            get: { selectedExistingCrateID?.uuidString ?? "" },
                            set: { newValue in
                                selectedExistingCrateID = UUID(uuidString: newValue)
                            }
                        )
                    ) {
                        Text("Select Crate").tag("")
                        ForEach(availableCrates, id: \.id) { crate in
                            Text(crate.pathComponents.joined(separator: " / "))
                                .tag(crate.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 420)

                    Spacer(minLength: 0)
                }
            }

            Button(downloadButtonTitle) {
                runDownload()
            }
            .disabled(!canDownload)

            HStack(spacing: 8) {
                Circle()
                    .fill(dependencyBadgeColor)
                    .frame(width: 10, height: 10)
                Text(dependencyBadgeText)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(dependencyBadgeColor)
            }

            Text("Destination root: \(destinationFolderURL.path)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if crateAssignmentMode == .none {
                Text("No crate will be updated for this download.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let lastSeratoWriteStatusMessage {
                Text(lastSeratoWriteStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var id3Card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MP3 ID3 Tags")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Picker("Source", selection: $lookupSourceSelection) {
                    ForEach(OnlineTrackMetadataLookupService.SourceSelection.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)

                Button("Lookup ID3 Online") {
                    runID3Lookup()
                }
                .disabled(isSearchingLookup)

                if isSearchingLookup {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 0)
            }

            Toggle("Auto Lookup after Load Info", isOn: $autoLookupAfterLoadInfo)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let lookupErrorMessage {
                Text(lookupErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !lookupResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lookup Results")
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(lookupResults.prefix(8)) { candidate in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(candidate.source.displayName): \(candidate.title.isEmpty ? "(untitled)" : candidate.title)")
                                                .font(.callout.weight(.semibold))
                                            Text(summary(for: candidate))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                        Button("Use All") {
                                            applyLookupCandidate(candidate)
                                        }
                                        .controlSize(.small)
                                    }

                                    HStack(spacing: 6) {
                                        if !candidate.title.isEmpty {
                                            fieldApplyButton("Title") { id3Title = candidate.title }
                                        }
                                        if !candidate.artist.isEmpty {
                                            fieldApplyButton("Artist") { id3Artist = candidate.artist }
                                        }
                                        if !candidate.album.isEmpty {
                                            fieldApplyButton("Album") { id3Album = candidate.album }
                                        }
                                        if !candidate.genre.isEmpty {
                                            fieldApplyButton("Genre") { id3Genre = candidate.genre }
                                        }
                                        if candidate.year != nil {
                                            fieldApplyButton("Year") { id3Year = candidate.year.map(String.init) ?? "" }
                                        }
                                        if candidate.bpm != nil {
                                            fieldApplyButton("BPM") { id3BPM = candidate.bpm.map { String(format: "%.0f", $0) } ?? "" }
                                        }
                                        if !candidate.comment.isEmpty {
                                            fieldApplyButton("Comment") { id3Comment = candidate.comment }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }

            fieldRow("Title", text: $id3Title)
            fieldRow("Artist", text: $id3Artist)
            fieldRow("Album", text: $id3Album)
            fieldRow("Genre", text: $id3Genre)
            fieldRow("Year", text: $id3Year)
            fieldRow("BPM", text: $id3BPM)
            fieldRow("Key", text: $id3Key)
            fieldRow("Comment", text: $id3Comment)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var recentDownloadsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 5 Downloads")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }

            ForEach(recentDownloads) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                    Text(item.fileName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(item.crateLabel) • \(formattedTimestamp(item.downloadedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private func fieldRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func fieldApplyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = destinationFolderURL

        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    private func loadVideoInfo() {
        guard let videoURL = parsedVideoURL else {
            errorMessage = "Paste a valid URL first."
            return
        }

        isLoadingInfo = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.fetchVideoInfo(videoURL: videoURL)
                }.value

                await MainActor.run {
                    loadedInfo = info
                    id3Title = info.title
                    id3Artist = info.uploader
                    id3Album = info.channel
                    id3Comment = info.webpageURL?.absoluteString ?? ""
                    if info.uploadDate.count >= 4 {
                        id3Year = String(info.uploadDate.prefix(4))
                    } else {
                        id3Year = ""
                    }
                    lookupResults = []
                    lookupErrorMessage = nil
                    errorMessage = nil

                    if autoLookupAfterLoadInfo {
                        runID3Lookup()
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isLoadingInfo = false
            }
        }
    }

    private func runDownload() {
        guard let videoURL = parsedVideoURL else {
            errorMessage = "Paste a valid URL first."
            return
        }

        guard dependencyReady else {
            errorMessage = dependencyStatusMessage ?? "yt-dlp and ffmpeg are required."
            return
        }

        isDownloading = true
        errorMessage = nil
        successMessage = nil

        let destinationFolderURL = destinationFolderURL
        let selectedFormat = selectedFormat
        let selectedQuality = selectedQuality
        let selectedBitrateKbps = supportsExplicitBitrate ? selectedBitrate.kbps : nil
        let crateAssignmentMode = crateAssignmentMode
        let selectedExistingCrate = selectedExistingCrate
        let loadedInfoSnapshot = loadedInfo
        let baseMetadata = buildMetadataForSave(
            fallbackTitle: loadedInfoSnapshot?.title,
            fallbackArtist: loadedInfoSnapshot?.uploader,
            fallbackAlbum: loadedInfoSnapshot?.channel,
            fallbackComment: loadedInfoSnapshot?.webpageURL?.absoluteString
        )
        let metadataForDownload = baseMetadata
        let cratePrefix = normalizedCratePrefix
        let subcratesDirectory = libraryService.subcratesDirectory
        let rootDirectory = libraryService.rootDirectory
        let databaseFileURL = libraryService.databaseFile

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.downloadAudio(
                        .init(
                            videoURL: videoURL,
                            destinationFolderURL: destinationFolderURL,
                            audioFormat: selectedFormat,
                            audioQuality: selectedQuality,
                            audioBitrateKbps: selectedBitrateKbps,
                            metadata: metadataForDownload
                        )
                    )
                }.value

                var id3MetadataWarning: String?
                var seratoMetadataWarning: String?
                var seratoWriteOutcome: SeratoWriteOutcome = .unchanged
                var metadataForDatabaseWrite = baseMetadata

                let fallbackInfo: YouTubeAudioImportService.VideoInfo?
                if let loadedInfoSnapshot {
                    fallbackInfo = loadedInfoSnapshot
                } else {
                    fallbackInfo = try? await Task.detached(priority: .utility) {
                        try YouTubeAudioImportService.fetchVideoInfo(videoURL: videoURL)
                    }.value
                }

                metadataForDatabaseWrite = enrichMetadata(
                    metadataForDatabaseWrite,
                    fallbackInfo: fallbackInfo,
                    downloadedTitle: result.title
                )

                if selectedFormat == .mp3 {
                    do {
                        try SeratoTrackMetadataEditor.writeID3Tags(
                            fileURL: result.outputFileURL,
                            metadata: metadataForDatabaseWrite
                        )
                    } catch {
                        id3MetadataWarning = "ID3 write failed: \(error.localizedDescription)"
                    }
                }

                do {
                    seratoWriteOutcome = try writeSeratoMetadataForDownloadedFile(
                        fileURL: result.outputFileURL,
                        rootDirectory: rootDirectory,
                        databaseFileURL: databaseFileURL,
                        metadata: metadataForDatabaseWrite
                    )
                } catch {
                    seratoMetadataWarning = "Serato DB write failed: \(error.localizedDescription)"
                }

                let crateResult: AddMusicImportService.CrateCreationResult?
                switch crateAssignmentMode {
                case .dated:
                    crateResult = try AddMusicImportService.createDatedCrate(
                        forAudioFiles: [result.outputFileURL],
                        crateNamePrefix: cratePrefix,
                        subcratesDirectory: subcratesDirectory,
                        rootDirectory: rootDirectory
                    )
                case .existing:
                    guard let selectedExistingCrate else {
                        throw AddMusicImportService.ImportError.missingCrateFileURL
                    }
                    crateResult = try AddMusicImportService.appendAudioFiles(
                        [result.outputFileURL],
                        toExistingCrate: selectedExistingCrate,
                        rootDirectory: rootDirectory
                    )
                case .none:
                    crateResult = nil
                }

                await MainActor.run {
                    let crateLabel: String
                    if let crateResult {
                        successMessage = "Downloaded \(result.outputFileURL.lastPathComponent) and saved to crate \(crateResult.crateName)."
                        crateLabel = "Crate: \(crateResult.crateName)"
                    } else {
                        successMessage = "Downloaded \(result.outputFileURL.lastPathComponent) with no crate assignment."
                        crateLabel = "No Crate"
                    }

                    if let id3MetadataWarning, !id3MetadataWarning.isEmpty {
                        successMessage = (successMessage ?? "") + " \(id3MetadataWarning)"
                    }

                    if let seratoMetadataWarning, !seratoMetadataWarning.isEmpty {
                        successMessage = (successMessage ?? "") + " \(seratoMetadataWarning)"
                        lastSeratoWriteStatusMessage = "Serato DB: write failed"
                    } else {
                        switch seratoWriteOutcome {
                        case .inserted:
                            lastSeratoWriteStatusMessage = "Serato DB: inserted new track row and wrote metadata"
                        case .updated:
                            lastSeratoWriteStatusMessage = "Serato DB: updated existing track metadata"
                        case .unchanged:
                            lastSeratoWriteStatusMessage = "Serato DB: track row already up to date"
                        }
                    }

                    appendRecentDownload(
                        title: loadedInfo?.title ?? result.title,
                        fileName: result.outputFileURL.lastPathComponent,
                        crateLabel: crateLabel
                    )
                    resetAfterSuccessfulDownload()

                    errorMessage = nil
                    onLibraryChanged()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isDownloading = false
            }
        }
    }

    private var normalizedCratePrefix: String {
        let trimmed = cratePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Music" : trimmed
    }

    private func buildMetadataForSave(
        fallbackTitle: String?,
        fallbackArtist: String?,
        fallbackAlbum: String?,
        fallbackComment: String?
    ) -> SeratoTrackMetadataUpdate {
        let resolvedTitle = resolvePreferredValue(id3Title, fallbackTitle)
        let resolvedArtist = resolvePreferredValue(id3Artist, fallbackArtist)
        let resolvedAlbum = resolvePreferredValue(id3Album, fallbackAlbum)
        let resolvedComment = resolvePreferredValue(id3Comment, fallbackComment)

        return SeratoTrackMetadataUpdate(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            genre: id3Genre,
            comment: resolvedComment,
            key: id3Key,
            bpm: Double(id3BPM.trimmingCharacters(in: .whitespacesAndNewlines)),
            year: Int(id3Year.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private func enrichMetadata(
        _ metadata: SeratoTrackMetadataUpdate,
        fallbackInfo: YouTubeAudioImportService.VideoInfo?,
        downloadedTitle: String
    ) -> SeratoTrackMetadataUpdate {
        var out = metadata

        if out.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.title = fallbackInfo?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if out.title.isEmpty {
                out.title = downloadedTitle
            }
        }

        if out.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.artist = fallbackInfo?.uploader.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        if out.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.album = fallbackInfo?.channel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        if out.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.comment = fallbackInfo?.webpageURL?.absoluteString ?? ""
        }

        if out.year == nil,
           let uploadDate = fallbackInfo?.uploadDate,
           uploadDate.count >= 4,
           let parsedYear = Int(uploadDate.prefix(4)) {
            out.year = parsedYear
        }

        return out
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        return String(format: "%d:%02d", minutes, remaining)
    }

    private func formattedUploadDate(_ yyyymmdd: String) -> String {
        guard yyyymmdd.count == 8 else { return yyyymmdd }
        let year = yyyymmdd.prefix(4)
        let monthStart = yyyymmdd.index(yyyymmdd.startIndex, offsetBy: 4)
        let monthEnd = yyyymmdd.index(yyyymmdd.startIndex, offsetBy: 6)
        let month = yyyymmdd[monthStart..<monthEnd]
        let day = yyyymmdd.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatSupportsExplicitBitrate(_ format: YouTubeAudioImportService.AudioFormat) -> Bool {
        switch format {
        case .mp3, .aac, .opus, .m4a:
            return true
        case .flac, .wav:
            return false
        }
    }

    private func checkDependencies() {
        let status = YouTubeAudioImportService.dependencyStatus()
        dependencyReady = status.isReady

        if status.isReady {
            dependencyStatusMessage = "Ready: yt-dlp at \(status.ytDLPPath ?? "") and ffmpeg at \(status.ffmpegPath ?? "")."
            return
        }

        var missing: [String] = []
        if status.ytDLPPath == nil { missing.append("yt-dlp") }
        if status.ffmpegPath == nil { missing.append("ffmpeg") }
        dependencyStatusMessage = "Missing dependencies: \(missing.joined(separator: ", ")). Install with Homebrew (brew install yt-dlp ffmpeg)."
    }

    private func appendRecentDownload(title: String, fileName: String, crateLabel: String) {
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fileName : title
        recentDownloads.insert(
            RecentDownload(
                title: resolvedTitle,
                fileName: fileName,
                crateLabel: crateLabel,
                downloadedAt: Date()
            ),
            at: 0
        )
        if recentDownloads.count > 5 {
            recentDownloads = Array(recentDownloads.prefix(5))
        }
    }

    private func resetAfterSuccessfulDownload() {
        urlText = ""
        loadedInfo = nil
        id3Title = ""
        id3Artist = ""
        id3Album = ""
        id3Genre = ""
        id3Comment = ""
        id3Key = ""
        id3BPM = ""
        id3Year = ""
        lookupResults = []
        lookupErrorMessage = nil
    }

    private func runID3Lookup() {
        isSearchingLookup = true
        lookupErrorMessage = nil

        let query = OnlineTrackMetadataLookupService.Query(
            title: id3Title,
            artist: id3Artist,
            album: id3Album
        )
        let sourceSelection = lookupSourceSelection

        Task {
            do {
                let results = try await OnlineTrackMetadataLookupService.lookup(
                    query: query,
                    sourceSelection: sourceSelection
                )

                await MainActor.run {
                    lookupResults = results
                    if results.isEmpty {
                        lookupErrorMessage = "No metadata matches found."
                    }
                }
            } catch {
                await MainActor.run {
                    lookupErrorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isSearchingLookup = false
            }
        }
    }

    private func applyLookupCandidate(_ candidate: OnlineTrackMetadataCandidate) {
        if !candidate.title.isEmpty {
            id3Title = candidate.title
        }
        if !candidate.artist.isEmpty {
            id3Artist = candidate.artist
        }
        if !candidate.album.isEmpty {
            id3Album = candidate.album
        }
        if !candidate.genre.isEmpty {
            id3Genre = candidate.genre
        }
        if let year = candidate.year {
            id3Year = String(year)
        }
        if let bpm = candidate.bpm {
            id3BPM = String(format: "%.0f", bpm)
        }
        if !candidate.comment.isEmpty {
            id3Comment = candidate.comment
        }
    }

    private func summary(for candidate: OnlineTrackMetadataCandidate) -> String {
        [
            candidate.artist,
            candidate.album,
            candidate.genre,
            candidate.year.map(String.init) ?? ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    }

    private func writeSeratoMetadataForDownloadedFile(
        fileURL: URL,
        rootDirectory: URL,
        databaseFileURL: URL,
        metadata: SeratoTrackMetadataUpdate
    ) throws -> SeratoWriteOutcome {
        if FileManager.default.fileExists(atPath: databaseFileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        }

        let original = try Data(contentsOf: databaseFileURL)
        let defaultStoredPath = SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)
        let storedPath = findExistingStoredPath(
            for: fileURL,
            rootDirectory: rootDirectory,
            in: original
        ) ?? defaultStoredPath

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

        if ensured.didInsert {
            return .inserted
        }
        if rewritten.didRewrite {
            return .updated
        }
        return .unchanged
    }

    private func findExistingStoredPath(
        for fileURL: URL,
        rootDirectory: URL,
        in databaseData: Data
    ) -> String? {
        let targetPaths = canonicalFilePaths(for: fileURL)

        for chunk in SeratoChunkCodec.readChunks(from: databaseData) where chunk.tag == "otrk" {
            let fields = SeratoChunkCodec.readChunks(from: chunk.payload)
            guard let pfil = fields.first(where: { $0.tag == "pfil" }) else { continue }

            let storedPath = SeratoChunkCodec.decodeUTF16BEString(pfil.payload)
            let resolvedURL = SeratoLibraryLocator.resolve(seratoStoredPath: storedPath, rootDirectory: rootDirectory)
            if targetPaths.contains(canonicalPathString(for: resolvedURL)) {
                return storedPath
            }
        }

        return nil
    }

    private func canonicalFilePaths(for fileURL: URL) -> Set<String> {
        var paths: Set<String> = []
        paths.insert(canonicalPathString(for: fileURL))
        paths.insert(canonicalPathString(for: fileURL.standardizedFileURL))
        paths.insert(canonicalPathString(for: fileURL.resolvingSymlinksInPath().standardizedFileURL))
        return paths
    }

    private func canonicalPathString(for fileURL: URL) -> String {
        var path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path

        // macOS temp and some mounted paths can differ only by the /private prefix.
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }

        return path
    }

    private func resolvePreferredValue(_ primary: String, _ fallback: String?) -> String {
        let primaryTrimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primaryTrimmed.isEmpty {
            return primaryTrimmed
        }
        return fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizeVideoURL(from rawText: String) -> URL? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            return nil
        }

        guard host.contains("youtube.com") || host.contains("youtu.be") else {
            return nil
        }

        return url
    }
}