import Foundation

public enum YouTubeAudioImportService {
    public struct DependencyStatus: Sendable {
        public let ytDLPPath: String?
        public let ffmpegPath: String?

        public var isReady: Bool {
            ytDLPPath != nil && ffmpegPath != nil
        }
    }

    public enum AudioFormat: String, CaseIterable, Sendable {
        case mp3
        case m4a
        case aac
        case flac
        case wav
        case opus

        public var displayName: String {
            rawValue.uppercased()
        }
    }

    public enum AudioQuality: String, CaseIterable, Sendable {
        case best = "0"
        case high = "2"
        case medium = "5"
        case low = "9"

        public var displayName: String {
            switch self {
            case .best:
                return "Best"
            case .high:
                return "High"
            case .medium:
                return "Medium"
            case .low:
                return "Low"
            }
        }
    }

    public enum ImportError: Error, LocalizedError {
        case emptySearchQuery
        case invalidVideoURL
        case ytDLPNotFound
        case commandFailed(String)
        case invalidMetadataPayload
        case missingOutputFilePath
        case outputFileNotFound(URL)

        public var errorDescription: String? {
            switch self {
            case .emptySearchQuery:
                return "Enter a track title or artist before searching YouTube."
            case .invalidVideoURL:
                return "Paste a valid YouTube URL first."
            case .ytDLPNotFound:
                return "yt-dlp is not installed or not in PATH. Install yt-dlp to enable YouTube import."
            case let .commandFailed(message):
                return "yt-dlp failed: \(message)"
            case .invalidMetadataPayload:
                return "Could not parse video metadata from yt-dlp output."
            case .missingOutputFilePath:
                return "yt-dlp did not report the output audio file path."
            case let .outputFileNotFound(url):
                return "Download finished but output file was not found at \(url.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .emptySearchQuery:
                return "Provide at least a title, artist, or both, then search again."
            case .invalidVideoURL:
                return "Use a full https://www.youtube.com/... or https://youtu.be/... link."
            case .ytDLPNotFound:
                return "Install with Homebrew: brew install yt-dlp"
            case .commandFailed:
                return "Verify the URL is accessible and try again."
            case .invalidMetadataPayload:
                return "Try again or update yt-dlp if the site format changed."
            case .missingOutputFilePath, .outputFileNotFound:
                return "Try again and check destination folder permissions."
            }
        }
    }

    public struct VideoInfo: Sendable {
        public let id: String
        public let title: String
        public let uploader: String
        public let channel: String
        public let durationSeconds: Int?
        public let thumbnailURL: URL?
        public let webpageURL: URL?
        public let uploadDate: String
        public let description: String
    }

    public struct SearchResult: Identifiable, Sendable, Hashable {
        public var id: String { videoID }

        public let videoID: String
        public let title: String
        public let channel: String
        public let durationSeconds: Int?
        public let webpageURL: URL
        public let thumbnailURL: URL?

        public init(
            videoID: String,
            title: String,
            channel: String,
            durationSeconds: Int?,
            webpageURL: URL,
            thumbnailURL: URL?
        ) {
            self.videoID = videoID
            self.title = title
            self.channel = channel
            self.durationSeconds = durationSeconds
            self.webpageURL = webpageURL
            self.thumbnailURL = thumbnailURL
        }
    }

    public struct DownloadRequest: Sendable {
        public let videoURL: URL
        public let destinationFolderURL: URL
        public let audioFormat: AudioFormat
        public let audioQuality: AudioQuality
        public let audioBitrateKbps: Int?
        public let metadata: SeratoTrackMetadataUpdate?

        public init(
            videoURL: URL,
            destinationFolderURL: URL,
            audioFormat: AudioFormat,
            audioQuality: AudioQuality,
            audioBitrateKbps: Int?,
            metadata: SeratoTrackMetadataUpdate?
        ) {
            self.videoURL = videoURL
            self.destinationFolderURL = destinationFolderURL
            self.audioFormat = audioFormat
            self.audioQuality = audioQuality
            self.audioBitrateKbps = audioBitrateKbps
            self.metadata = metadata
        }
    }

    public struct DownloadResult: Sendable {
        public let outputFileURL: URL
        public let title: String
    }

    public static func fetchVideoInfo(videoURL: URL) throws -> VideoInfo {
        guard let scheme = videoURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ImportError.invalidVideoURL
        }

        // Query only required fields to avoid huge JSON output that can stall
        // process pipes in GUI environments.
        let args = [
            "--no-playlist",
            "--skip-download",
            "--no-progress",
            "--no-warnings",
            "--print", "%(id)s",
            "--print", "%(title)s",
            "--print", "%(uploader)s",
            "--print", "%(channel)s",
            "--print", "%(duration)s",
            "--print", "%(thumbnail)s",
            "--print", "%(webpage_url)s",
            "--print", "%(upload_date)s",
            videoURL.absoluteString
        ]
        let result = try runYTCommand(arguments: args)
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let id = cleanedPrintedValue(lines[safe: 0] ?? "")
        let title = cleanedPrintedValue(lines[safe: 1] ?? "")
        let uploader = cleanedPrintedValue(lines[safe: 2] ?? "")
        let channel = cleanedPrintedValue(lines[safe: 3] ?? "")
        let durationSeconds = Int(cleanedPrintedValue(lines[safe: 4] ?? ""))
        let thumbnail = cleanedPrintedValue(lines[safe: 5] ?? "")
        let webpageURL = cleanedPrintedValue(lines[safe: 6] ?? "")
        let uploadDate = cleanedPrintedValue(lines[safe: 7] ?? "")

        guard !title.isEmpty else {
            throw ImportError.invalidMetadataPayload
        }

        return VideoInfo(
            id: id,
            title: title,
            uploader: uploader,
            channel: channel,
            durationSeconds: durationSeconds,
            thumbnailURL: URL(string: thumbnail),
            webpageURL: URL(string: webpageURL),
            uploadDate: uploadDate,
            description: ""
        )
    }

    public static func dependencyStatus(environment: [String: String] = ProcessInfo.processInfo.environment) -> DependencyStatus {
        let ytDLPPath = findExecutablePath(
            named: "yt-dlp",
            preferredPaths: preferredYTDLPPaths(),
            environment: environment
        )

        let ffmpegPath = findExecutablePath(
            named: "ffmpeg",
            preferredPaths: preferredFFmpegPaths(),
            environment: environment
        )

        return DependencyStatus(ytDLPPath: ytDLPPath, ffmpegPath: ffmpegPath)
    }

    /// yt-dlp must track YouTube's frequent site changes, so a Homebrew (or any
    /// on-PATH system) copy is preferred. When Homebrew isn't installed, the
    /// user-writable self-updating copy the app maintains is used as a fallback.
    private static func preferredYTDLPPaths() -> [String] {
        let managed = managedYTDLPURL().path
        return [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            FileManager.default.isExecutableFile(atPath: managed) ? managed : nil
        ].compactMap { $0 }
    }

    /// ffmpeg is resolved from Homebrew (or any system location on PATH). yt-dlp
    /// needs to be told where it is (see `downloadAudio`), because a GUI app
    /// launched from Finder has a minimal PATH that doesn't include Homebrew.
    private static func preferredFFmpegPaths() -> [String] {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
    }

    /// The directory containing ffmpeg (and ffprobe) to hand to yt-dlp via
    /// `--ffmpeg-location`, or nil when none can be found.
    private static func resolveFFmpegDirectory() -> String? {
        guard let ffmpegPath = findExecutablePath(
            named: "ffmpeg",
            preferredPaths: preferredFFmpegPaths(),
            environment: ProcessInfo.processInfo.environment
        ) else {
            return nil
        }
        return URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path
    }

    public struct DependencyInstallResult: Sendable {
        public let succeeded: Bool
        public let log: String
    }

    public enum DependencyInstallError: LocalizedError {
        case bootstrapScriptMissing
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .bootstrapScriptMissing:
                return "The bundled dependency installer was not found in the app."
            case let .launchFailed(message):
                return "Could not run the dependency installer: \(message)"
            }
        }
    }

    /// Runs the bundled `install-dependencies.sh` bootstrap (Homebrew + yt-dlp +
    /// ffmpeg + chromaprint) as the current user. Best-effort: the app still
    /// works with its bundled portable tools if this fails.
    public static func installDependencies() throws -> DependencyInstallResult {
        guard let scriptPath = bundledScriptPath(named: "install-dependencies.sh") else {
            throw DependencyInstallError.bootstrapScriptMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]

        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw DependencyInstallError.launchFailed(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(data: data, encoding: .utf8) ?? ""
        let ready = dependencyStatus().isReady
        return DependencyInstallResult(succeeded: ready, log: log)
    }

    private static func bundledScriptPath(named name: String) -> String? {
        let fileManager = FileManager.default
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("scripts/\(name)", isDirectory: false),
            bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
        ]

        for candidate in candidates.compactMap({ $0 }) where fileManager.isReadableFile(atPath: candidate.path) {
            return candidate.path
        }

        return nil
    }

    public static func searchVideos(query: String, maxResults: Int = 5) throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ImportError.emptySearchQuery
        }

        let safeCount = max(1, min(maxResults, 15))
        let searchTerm = "ytsearch\(safeCount):\(trimmedQuery)"
        let args = [
            "--flat-playlist",
            "--dump-json",
            "--no-warnings",
            "--skip-download",
            searchTerm
        ]

        let result = try runYTCommand(arguments: args)
        let lines = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var output: [SearchResult] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let videoID = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !videoID.isEmpty, !title.isEmpty else {
                continue
            }

            let channel =
                (json["channel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
                (json["uploader"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
                ""

            let durationSeconds: Int?
            if let duration = json["duration"] as? Int {
                durationSeconds = duration
            } else if let durationString = json["duration"] as? String {
                durationSeconds = Int(durationString)
            } else {
                durationSeconds = nil
            }

            let webpageURL: URL
            if let pageURLString = (json["webpage_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = URL(string: pageURLString),
               !pageURLString.isEmpty {
                webpageURL = parsed
            } else {
                webpageURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
            }

            let thumbnailURL: URL?
            if let thumb = (json["thumbnail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thumb.isEmpty {
                thumbnailURL = URL(string: thumb)
            } else {
                thumbnailURL = nil
            }

            output.append(
                SearchResult(
                    videoID: videoID,
                    title: title,
                    channel: channel,
                    durationSeconds: durationSeconds,
                    webpageURL: webpageURL,
                    thumbnailURL: thumbnailURL
                )
            )
        }

        return output
    }

    public static func downloadAudio(_ request: DownloadRequest) throws -> DownloadResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: request.destinationFolderURL, withIntermediateDirectories: true)

        let qualityArgument: String
        if let bitrate = request.audioBitrateKbps, bitrate > 0 {
            qualityArgument = "\(bitrate)K"
        } else {
            qualityArgument = request.audioQuality.rawValue
        }

        var args: [String] = [
            "--extract-audio",
            "--audio-format", request.audioFormat.rawValue,
            "--audio-quality", qualityArgument,
            "--no-playlist",
            "--no-progress",
            "--paths", request.destinationFolderURL.path,
            "--output", "%(title)s [%(id)s].%(ext)s",
            "--print", "after_move:filepath",
            request.videoURL.absoluteString
        ]

        var ffmpegPostProcessorArgs = "-loglevel error"
        if request.audioFormat == .mp3, let metadata = request.metadata {
            let metadataArgs = ffmpegMetadataArguments(metadata)
            if !metadataArgs.isEmpty {
                ffmpegPostProcessorArgs += " " + metadataArgs
            }
        }
        args.insert(contentsOf: ["--postprocessor-args", "ffmpeg:\(ffmpegPostProcessorArgs)"], at: 0)

        // A GUI app launched from Finder has a minimal PATH, so yt-dlp can't
        // find ffmpeg/ffprobe on its own. Point it at the resolved location
        // explicitly, otherwise audio extraction fails for every download.
        if let ffmpegDirectory = resolveFFmpegDirectory() {
            args.insert(contentsOf: ["--ffmpeg-location", ffmpegDirectory], at: 0)
        }

        let result = try runYTCommand(arguments: args)
        guard let outputPath = result.stdout
            .split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty }) else {
            throw ImportError.missingOutputFilePath
        }

        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ImportError.outputFileNotFound(outputURL)
        }

        // If ffmpeg metadata args were skipped or ignored, enforce ID3 here.
        if request.audioFormat == .mp3, let metadata = request.metadata {
            try SeratoTrackMetadataEditor.writeID3Tags(fileURL: outputURL, metadata: metadata)
        }

        let title = outputURL.deletingPathExtension().lastPathComponent
        return DownloadResult(outputFileURL: outputURL, title: title)
    }

    private static func ffmpegMetadataArguments(_ metadata: SeratoTrackMetadataUpdate) -> String {
        var args: [String] = []

        func append(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
            args.append("-metadata \(key)=\"\(escaped)\"")
        }

        append("title", metadata.title)
        append("artist", metadata.artist)
        append("album", metadata.album)
        append("genre", metadata.genre)
        append("comment", metadata.comment)
        append("TKEY", metadata.key)

        if let bpm = metadata.bpm {
            append("TBPM", String(format: "%.0f", bpm))
        }
        if let year = metadata.year {
            append("date", String(year))
        }

        return args.joined(separator: " ")
    }

    private static func runYTCommand(arguments: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let resolved = resolveYTDLPExecutable()
        process.executableURL = resolved.executable
        process.arguments = resolved.prefixArguments + arguments

        do {
            try process.run()
        } catch {
            throw ImportError.ytDLPNotFound
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.commandFailed(message.isEmpty ? "Unknown yt-dlp error" : message)
        }

        return (stdout, stderr)
    }

    private static func resolveYTDLPExecutable() -> (executable: URL, prefixArguments: [String]) {
        if let path = findExecutablePath(
            named: "yt-dlp",
            preferredPaths: preferredYTDLPPaths(),
            environment: ProcessInfo.processInfo.environment
        ) {
            return (URL(fileURLWithPath: path), [])
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["yt-dlp"])
    }

    // MARK: - Self-updating yt-dlp

    private static let lastYTDLPUpdateCheckDefaultsKey = "SeratoToolsLastYTDLPUpdateCheck"
    private static let ytDLPMacOSDownloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// User-writable location for a yt-dlp copy the app keeps current. Unlike
    /// the binary bundled inside the read-only app bundle, this one can update
    /// itself, so downloads keep working as YouTube changes over time.
    public static func managedYTDLPURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("SeratoTools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: false)
    }

    /// Ensures a user-writable yt-dlp exists and refreshes it to the latest
    /// release at most once per day. Best-effort and safe to call from a
    /// background task: it never throws and does nothing useful when offline.
    @discardableResult
    public static func refreshManagedYTDLPIfDue(
        force: Bool = false,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if !force,
           let last = userDefaults.object(forKey: lastYTDLPUpdateCheckDefaultsKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return false
        }

        do {
            try ensureManagedYTDLPInstalled()
            selfUpdateManagedYTDLP()
            userDefaults.set(Date(), forKey: lastYTDLPUpdateCheckDefaultsKey)
            return true
        } catch {
            return false
        }
    }

    private static func ensureManagedYTDLPInstalled() throws {
        let fileManager = FileManager.default
        let managedURL = managedYTDLPURL()
        if fileManager.isExecutableFile(atPath: managedURL.path) { return }

        try fileManager.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try downloadLatestYTDLP(to: managedURL)

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedURL.path)
        clearQuarantine(at: managedURL)
    }

    private static func downloadLatestYTDLP(to destination: URL) throws {
        let data = try Data(contentsOf: ytDLPMacOSDownloadURL)
        // The real binary is several MB; a tiny payload means an error page.
        guard data.count > 1_000_000 else {
            throw ImportError.commandFailed("Downloaded yt-dlp was unexpectedly small.")
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Runs `yt-dlp -U`, which checks the latest release and replaces the
    /// binary in place only when outdated. No-op when already current/offline.
    private static func selfUpdateManagedYTDLP() {
        let managedURL = managedYTDLPURL()
        guard FileManager.default.isExecutableFile(atPath: managedURL.path) else { return }

        let process = Process()
        process.executableURL = managedURL
        process.arguments = ["-U", "--no-progress"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best effort: keep the seeded copy if self-update can't run.
        }
    }

    private static func clearQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func findExecutablePath(
        named commandName: String,
        preferredPaths: [String],
        environment: [String: String]
    ) -> String? {
        let fileManager = FileManager.default

        for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        if let rawPATH = environment["PATH"], !rawPATH.isEmpty {
            for component in rawPATH.split(separator: ":") {
                let candidate = String(component) + "/" + commandName
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func cleanedPrintedValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NA" ? "" : trimmed
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}