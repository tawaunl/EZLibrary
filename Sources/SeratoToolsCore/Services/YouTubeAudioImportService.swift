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
        case invalidVideoURL
        case ytDLPNotFound
        case commandFailed(String)
        case invalidMetadataPayload
        case missingOutputFilePath
        case outputFileNotFound(URL)

        public var errorDescription: String? {
            switch self {
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
        let bundledYTDLP = bundledExecutablePath(named: "yt-dlp")
        let bundledFFmpeg = bundledExecutablePath(named: "ffmpeg")

        let ytDLPPath = findExecutablePath(
            named: "yt-dlp",
            preferredPaths: [
                bundledYTDLP,
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/usr/bin/yt-dlp"
            ].compactMap { $0 },
            environment: environment
        )

        let ffmpegPath = findExecutablePath(
            named: "ffmpeg",
            preferredPaths: [
                bundledFFmpeg,
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
                "/usr/bin/ffmpeg"
            ].compactMap { $0 },
            environment: environment
        )

        return DependencyStatus(ytDLPPath: ytDLPPath, ffmpegPath: ffmpegPath)
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
        let bundledYTDLP = bundledExecutablePath(named: "yt-dlp")

        if let path = findExecutablePath(
            named: "yt-dlp",
            preferredPaths: [
                bundledYTDLP,
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/usr/bin/yt-dlp"
            ].compactMap { $0 },
            environment: ProcessInfo.processInfo.environment
        ) {
            return (URL(fileURLWithPath: path), [])
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["yt-dlp"])
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

    private static func bundledExecutablePath(named name: String) -> String? {
        let fileManager = FileManager.default
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("bin/\(name)", isDirectory: false),
            bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
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