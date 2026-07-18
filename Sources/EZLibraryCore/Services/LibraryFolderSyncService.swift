import Foundation

public enum LibraryFolderSyncService {
    public struct SyncResult: Sendable {
        public let scannedAudioFiles: Int
        public let insertedTracks: Int
        public let alreadyPresentTracks: Int

        public init(scannedAudioFiles: Int, insertedTracks: Int, alreadyPresentTracks: Int) {
            self.scannedAudioFiles = scannedAudioFiles
            self.insertedTracks = insertedTracks
            self.alreadyPresentTracks = alreadyPresentTracks
        }
    }

    public enum SyncError: LocalizedError {
        case folderNotFound(URL)
        case noSupportedAudioFiles(URL)
        case databaseNotFound(URL)

        public var errorDescription: String? {
            switch self {
            case let .folderNotFound(folderURL):
                return "Folder not found: \(folderURL.path)."
            case let .noSupportedAudioFiles(folderURL):
                return "No supported audio files were found in \(folderURL.path)."
            case let .databaseNotFound(databaseURL):
                return "Serato database V2 was not found at \(databaseURL.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .folderNotFound:
                return "Choose a valid folder path and try syncing again."
            case .noSupportedAudioFiles:
                return "Add supported formats like mp3, m4a, aac, wav, aif, aiff, flac, alac, or ogg first."
            case .databaseNotFound:
                return "Open Serato once to initialize the library, then retry."
            }
        }
    }

    public static func syncAudioFolder(
        _ folderURL: URL,
        databaseFileURL: URL,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> SyncResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.folderNotFound(folderURL)
        }

        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw SyncError.databaseNotFound(databaseFileURL)
        }

        let discovered = AddMusicImportService.discoverAudioFiles(from: [folderURL], fileManager: fileManager)
        guard !discovered.isEmpty else {
            throw SyncError.noSupportedAudioFiles(folderURL)
        }

        return try syncAudioFiles(
            discovered,
            databaseFileURL: databaseFileURL,
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
    }

    public static func syncAudioFiles(
        _ audioFiles: [URL],
        databaseFileURL: URL,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> SyncResult {
        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw SyncError.databaseNotFound(databaseFileURL)
        }

        let normalizedAudioFiles = normalizedSupportedExistingFiles(audioFiles, fileManager: fileManager)
        guard !normalizedAudioFiles.isEmpty else {
            throw SyncError.noSupportedAudioFiles(databaseFileURL.deletingLastPathComponent())
        }

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        var data = try Data(contentsOf: databaseFileURL)

        var inserted = 0
        var alreadyPresent = 0

        for fileURL in normalizedAudioFiles {
            let storedPath = SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)
            let ensured = SeratoDatabaseWriter.ensuringTrackExists(
                forStoredPath: storedPath,
                metadata: fallbackMetadata(fromFilename: fileURL),
                in: data
            )
            data = ensured.data
            if ensured.didInsert {
                inserted += 1
            } else {
                alreadyPresent += 1
            }
        }

        if inserted > 0 {
            try AtomicFileWriter.write(data, to: databaseFileURL)
        }

        return SyncResult(
            scannedAudioFiles: normalizedAudioFiles.count,
            insertedTracks: inserted,
            alreadyPresentTracks: alreadyPresent
        )
    }

    private static func fallbackMetadata(fromFilename fileURL: URL) -> SeratoTrackMetadataUpdate {
        let rawBaseName = fileURL.deletingPathExtension().lastPathComponent
        let normalized = normalizeFilenameComponent(rawBaseName)
        let (artistGuess, titleGuess) = splitArtistAndTitle(from: normalized)

        return SeratoTrackMetadataUpdate(
            title: titleGuess,
            artist: artistGuess,
            album: "",
            genre: "",
            comment: "",
            key: "",
            bpm: nil,
            year: nil
        )
    }

    private static func splitArtistAndTitle(from baseName: String) -> (artist: String, title: String) {
        let separators = [" - ", " – ", " — ", " | ", " : "]
        for separator in separators {
            let parts = baseName.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }

            let artist = normalizeArtistGuess(normalizeFilenameComponent(parts[0]))
            let title = normalizeTitleGuess(normalizeFilenameComponent(parts.dropFirst().joined(separator: separator)))
            if !title.isEmpty {
                return (artist: artist, title: title)
            }
        }

        // Support compact patterns like "Artist-Title" when spaced separators aren't present.
        if !baseName.contains(" - "), let compactRange = baseName.range(of: "-") {
            let left = normalizeArtistGuess(normalizeFilenameComponent(String(baseName[..<compactRange.lowerBound])))
            let right = normalizeTitleGuess(normalizeFilenameComponent(String(baseName[compactRange.upperBound...])))
            if !left.isEmpty, !right.isEmpty,
               left.rangeOfCharacter(from: .letters) != nil,
               right.rangeOfCharacter(from: .letters) != nil {
                return (artist: left, title: right)
            }
        }

        return (artist: "", title: normalizeTitleGuess(baseName))
    }

    private static func normalizeFilenameComponent(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "_", with: " ")

        // Strip common leading index prefixes like "01 - " or "1. ".
        let indexPattern = #"^\s*\d{1,3}(?:\s*[-._)]\s*|\s+)"#
        value = value.replacingOccurrences(of: indexPattern, with: "", options: .regularExpression)

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeArtistGuess(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: #"\s+feat\.?\s+"#, with: " feat. ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\s+ft\.?\s+"#, with: " feat. ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeTitleGuess(_ raw: String) -> String {
        var value = raw

        value = removeInlineNoisyBracketDescriptors(from: value)

        // Strip common non-title download noise while keeping meaningful mix/remix info.
        while true {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if removeTrailingBracketDescriptorIfNoisy(from: &value) {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if removeTrailingInlineNoiseIfPresent(from: &value) {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                break
            }
        }

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeInlineNoisyBracketDescriptors(from value: String) -> String {
        let pattern = #"\s*[\(\[\{]([^\)\]\}]*)[\)\]\}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        var output = value
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: fullRange)

        for match in matches.reversed() {
            guard let descriptorRange = Range(match.range(at: 1), in: output),
                  let segmentRange = Range(match.range(at: 0), in: output) else {
                continue
            }

            let descriptor = output[descriptorRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard shouldStripTrailingNoiseDescriptor(descriptor), !shouldPreserveDJDescriptor(descriptor) else {
                continue
            }

            output.removeSubrange(segmentRange)
        }

        return output
    }

    private static func removeTrailingBracketDescriptorIfNoisy(from value: inout String) -> Bool {
        guard let range = value.range(of: #"\s*[\(\[\{]([^\)\]\}]*)[\)\]\}]\s*$"#, options: .regularExpression) else {
            return false
        }

        let segment = String(value[range])
        let descriptor = segment
            .replacingOccurrences(of: #"^[\s\(\[\{]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\)\]\}]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldStripTrailingNoiseDescriptor(descriptor), !shouldPreserveDJDescriptor(descriptor) else {
            return false
        }

        value.removeSubrange(range)
        return true
    }

    private static func removeTrailingInlineNoiseIfPresent(from value: inout String) -> Bool {
        let pattern = #"\s*[-–—|:]\s*(official\s+(video|audio)|music\s+video|lyric(s)?\s*(video)?|visualizer|audio|video|hq|hd|4k|free\s+download|out\s+now)\s*$"#
        guard let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return false
        }
        value.removeSubrange(range)
        return true
    }

    private static func shouldStripTrailingNoiseDescriptor(_ descriptor: String) -> Bool {
        let normalized = descriptor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.isEmpty {
            return true
        }

        let noisyPatterns = [
            #"^official(\s+(video|audio))?$"#,
            #"^music\s+video$"#,
            #"^lyric(s)?(\s+video)?$"#,
            #"^visualizer$"#,
            #"^audio$"#,
            #"^video$"#,
            #"^hq$"#,
            #"^hd$"#,
            #"^4k$"#,
            #"^free\s+download$"#,
            #"^out\s+now$"#
        ]

        return noisyPatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func shouldPreserveDJDescriptor(_ descriptor: String) -> Bool {
        let normalized = descriptor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let preserveTokens = [
            "quick hit",
            "intro",
            "extended",
            "remix",
            "edit",
            "radio edit",
            "club edit",
            "acapella",
            "instrumental",
            "transition",
            "bootleg",
            "mashup",
            "flip",
            "clean",
            "dirty",
            "explicit"
        ]

        return preserveTokens.contains { normalized.contains($0) }
    }

    private static func normalizedSupportedExistingFiles(_ files: [URL], fileManager: FileManager) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []

        for file in files {
            let normalized = file.standardizedFileURL
            guard AddMusicImportService.supportedAudioExtensions.contains(normalized.pathExtension.lowercased()) else {
                continue
            }
            guard fileManager.fileExists(atPath: normalized.path) else { continue }

            if seen.insert(normalized.path).inserted {
                output.append(normalized)
            }
        }

        return output.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}