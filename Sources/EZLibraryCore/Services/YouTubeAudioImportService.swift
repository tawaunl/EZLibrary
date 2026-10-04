// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import CryptoKit
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

    /// Returns the installed yt-dlp version string (e.g. "2024.08.06"), or nil
    /// when yt-dlp can't be found or run. Used to give the user visible feedback
    /// about which yt-dlp build is active when they check dependencies.
    public static func installedYTDLPVersion() -> String? {
        guard let result = try? runYTCommand(arguments: ["--version"]) else {
            return nil
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
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
        return try runSearch(searchTerm: "ytsearch\(safeCount):\(trimmedQuery)", fallbackYouTube: true)
    }

    /// Searches BOTH YouTube and SoundCloud (yt-dlp can download from either),
    /// drops results that look like music videos rather than audio, and merges
    /// the two sources so version variants (Extended Mix, Intro, Remix, …)
    /// surface. Failures on one source degrade to the other.
    public static func searchAudioSuggestions(query: String, maxResults: Int = 12) throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ImportError.emptySearchQuery
        }

        let perSource = max(1, min(maxResults, 15))
        let youtube = (try? runSearch(searchTerm: "ytsearch\(perSource):\(trimmedQuery)", fallbackYouTube: true)) ?? []
        let soundcloud = (try? runSearch(searchTerm: "scsearch\(perSource):\(trimmedQuery)", fallbackYouTube: false)) ?? []

        var seen = Set<String>()
        var merged: [SearchResult] = []
        for result in youtube + soundcloud {
            guard !isLikelyMusicVideo(title: result.title) else { continue }
            guard seen.insert(result.webpageURL.absoluteString.lowercased()).inserted else { continue }
            merged.append(result)
        }
        return merged
    }

    /// Heuristic: titles that advertise a music/official video (rather than an
    /// audio upload) are excluded from download suggestions.
    static func isLikelyMusicVideo(title: String) -> Bool {
        let lower = title.lowercased()
        let markers = [
            "official video",
            "official music video",
            "music video",
            "(video)",
            "[video]",
            "official mv",
            "m/v",
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func runSearch(searchTerm: String, fallbackYouTube: Bool) throws -> [SearchResult] {
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
            } else if fallbackYouTube {
                webpageURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
            } else {
                // No usable page URL (e.g. a SoundCloud entry) — skip it rather
                // than fabricate a YouTube link.
                continue
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

    /// Quotes one value for `--postprocessor-args`, which yt-dlp splits with
    /// POSIX `shlex` rules before handing the pieces to ffmpeg as argv.
    ///
    /// Inside single quotes shlex treats every character literally, so the only
    /// case needing care is an embedded single quote: close the run, emit an
    /// escaped quote, reopen. Double quotes are *not* safe here — shlex unescapes
    /// `\\` inside them, so a value containing `\"` ends the quoted run early and
    /// every word after it becomes a new ffmpeg argument. Track metadata reaches
    /// this from remote lookups and YouTube titles, so a crafted title could
    /// append `-y /some/path` and have ffmpeg overwrite an arbitrary file.
    static func shellQuotedForPostprocessor(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func ffmpegMetadataArguments(_ metadata: SeratoTrackMetadataUpdate) -> String {
        var args: [String] = []

        func append(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            args.append("-metadata " + shellQuotedForPostprocessor("\(key)=\(trimmed)"))
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

    /// Fetches a URL synchronously with a timeout. `Data(contentsOf:)` has no
    /// timeout at all, so a stalled connection would pin the calling task for
    /// as long as the socket stayed open.
    private static func fetch(_ url: URL, timeout: TimeInterval = 60) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("EZLibrary", forHTTPHeaderField: "User-Agent")

        // The completion handler runs on a URLSession queue, so the result
        // crosses a concurrency boundary — it lands in a box rather than in
        // captured vars, the same way ProcessRunner drains its pipes.
        final class Box: @unchecked Sendable {
            var payload: Data?
            var failure: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, _, error in
            box.payload = data
            box.failure = error
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            throw ImportError.commandFailed("The download timed out.")
        }
        if let failure = box.failure { throw failure }
        guard let payload = box.payload else {
            throw ImportError.commandFailed("The download returned no data.")
        }
        return payload
    }

    /// The checksum manifest published alongside every yt-dlp release.
    private static let ytDLPChecksumsURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!

    /// Pulls the expected SHA-256 for `yt-dlp_macos` out of the release's
    /// `SHA2-256SUMS` manifest, whose lines read `<hex>  <filename>`.
    static func expectedYTDLPDigest(fromChecksumManifest manifest: String, filename: String = "yt-dlp_macos") -> String? {
        for line in manifest.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, String(fields[fields.count - 1]) == filename else { continue }
            let digest = String(fields[0]).lowercased()
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
            return digest
        }
        return nil
    }

    private static func downloadLatestYTDLP(to destination: URL) throws {
        let data = try fetch(ytDLPMacOSDownloadURL)
        // The real binary is several MB; a tiny payload means an error page.
        guard data.count > 1_000_000 else {
            throw ImportError.commandFailed("Downloaded yt-dlp was unexpectedly small.")
        }

        // This binary is about to be marked executable, have its quarantine
        // flag cleared, and be run. Check it against the digest yt-dlp
        // publishes with the release rather than trusting whatever arrived —
        // the size check above only catches an error page, not a substitution.
        if let manifest = try? fetch(ytDLPChecksumsURL),
           let manifestText = String(data: manifest, encoding: .utf8),
           let expected = expectedYTDLPDigest(fromChecksumManifest: manifestText) {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw ImportError.commandFailed(
                    "The downloaded yt-dlp didn't match the checksum published with the release, so it wasn't installed."
                )
            }
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