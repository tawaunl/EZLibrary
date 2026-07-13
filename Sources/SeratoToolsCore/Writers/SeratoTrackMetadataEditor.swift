import Foundation

/// Applies track metadata edits to both Serato `database V2` and audio file
/// ID3 tags (for MP3 files).
public enum SeratoTrackMetadataEditor {
    public enum EditError: Error, LocalizedError {
        case trackNotFoundInDatabase(String)
        case metadataVerificationFailed(String)
        case fileTypeNotSupportedForID3(URL)
        case fileRenameFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .trackNotFoundInDatabase(path):
                return "Could not find this track in database V2 for path: \(path)"
            case let .metadataVerificationFailed(path):
                return "Metadata save could not be verified in database V2 for path: \(path)"
            case let .fileTypeNotSupportedForID3(fileURL):
                return "ID3 writing is only supported for MP3 files. Unsupported file: \(fileURL.lastPathComponent)"
            case let .fileRenameFailed(reason):
                return "Could not rewrite file name from metadata: \(reason)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .trackNotFoundInDatabase:
                return "Reload the library and retry. If it still fails, the track path in database V2 may have changed."
            case .metadataVerificationFailed:
                return "Retry once. If the issue persists, refresh Serato's library view or restart Serato DJ to force a metadata reload."
            case .fileTypeNotSupportedForID3:
                return "Metadata can still be written to Serato database V2 for this track type."
            case .fileRenameFailed:
                return "Check file permissions and try again."
            }
        }
    }

    public static func update(
        track: Track,
        metadata: SeratoTrackMetadataUpdate,
        databaseFileURL: URL,
        rewriteFilenameFromMetadata: Bool = true
    ) throws {
        // Update on-disk ID3 first so we never commit DB-only edits when a
        // file-tag write fails.
        try writeID3Tags(fileURL: track.fileURL, metadata: metadata)

        if FileManager.default.fileExists(atPath: databaseFileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        }

        let libraryDirectory = databaseFileURL.deletingLastPathComponent()
        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        let original = try Data(contentsOf: databaseFileURL)
        let candidateStoredPaths = storedPathCandidates(
            track: track,
            rootDirectory: rootDirectory,
            databaseData: original
        )

        let matchedOldStoredPath = firstMatchingStoredPath(
            candidates: candidateStoredPaths,
            in: original
        ) ?? candidateStoredPaths[0]

        let originalFileURL = track.fileURL
        let renamedFileURL: URL?
        if rewriteFilenameFromMetadata {
            renamedFileURL = proposedRenamedFileURL(
                for: originalFileURL,
                metadata: metadata
            )
        } else {
            renamedFileURL = nil
        }

        var finalFileURL = originalFileURL
        var didMoveFile = false
        if let renamedFileURL, renamedFileURL != originalFileURL {
            do {
                try FileManager.default.moveItem(at: originalFileURL, to: renamedFileURL)
                finalFileURL = renamedFileURL
                didMoveFile = true
            } catch {
                throw EditError.fileRenameFailed(error.localizedDescription)
            }
        }

        let finalStoredPath = SeratoLibraryLocator.seratoStoredPath(for: finalFileURL, rootDirectory: rootDirectory)

        do {
            var rewritten = SeratoDatabaseWriter.rewritingMetadata(
                forStoredPath: matchedOldStoredPath,
                metadata: metadata,
                in: original
            )

            guard rewritten.didRewrite else {
                throw EditError.trackNotFoundInDatabase(track.seratoStoredPath)
            }

            if finalStoredPath != matchedOldStoredPath {
                let pathRewrite = SeratoDatabaseWriter.rewritingPath(
                    matchedOldStoredPath,
                    to: finalStoredPath,
                    in: rewritten.data
                )
                rewritten = (data: pathRewrite.data, didRewrite: rewritten.didRewrite)
                try rewriteCratesPath(
                    oldStoredPath: matchedOldStoredPath,
                    newStoredPath: finalStoredPath,
                    libraryDirectory: libraryDirectory
                )
            }

            try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)

            guard verifyPersistedMetadata(
                metadata,
                in: rewritten.data,
                rootDirectory: rootDirectory,
                fileURL: finalFileURL
            ) else {
                throw EditError.metadataVerificationFailed(finalStoredPath)
            }
        } catch {
            if didMoveFile {
                try? FileManager.default.moveItem(at: finalFileURL, to: originalFileURL)
            }
            throw error
        }
    }

    public static func writeID3Tags(fileURL: URL, metadata: SeratoTrackMetadataUpdate) throws {
        try writeID3IfSupported(fileURL: fileURL, metadata: metadata)
    }

    private static func writeID3IfSupported(fileURL: URL, metadata: SeratoTrackMetadataUpdate) throws {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "mp3" else {
            return
        }

        var data = try Data(contentsOf: fileURL)
        let audioBody: Data
        let originalTag: Data?

        if data.count >= 10, String(data: data.prefix(3), encoding: .ascii) == "ID3" {
            let size = decodeSyncSafeInt(Array(data[6...9]))
            let end = min(data.count, 10 + size)
            originalTag = data.subdata(in: 0..<end)
            audioBody = data.subdata(in: end..<data.count)
        } else {
            originalTag = nil
            audioBody = data
        }

        var tagFrames = buildID3v24Frames(metadata: metadata)

        // Cover art: apply new art when provided, otherwise preserve whatever
        // was already embedded in the file.
        if let newArtwork = metadata.artwork {
            tagFrames.append(ID3ArtworkCodec.apicFrame(for: newArtwork))
        } else if let originalTag, let existing = ID3ArtworkCodec.extractArtwork(fromID3TagBytes: originalTag) {
            tagFrames.append(ID3ArtworkCodec.apicFrame(for: existing))
        }

        // Preserve any other frames (track number, lyrics, ReplayGain, etc.)
        // we don't explicitly rewrite, so edits never silently drop tag data.
        if let originalTag {
            tagFrames.append(
                ID3ArtworkCodec.preservedFrames(
                    fromID3TagBytes: originalTag,
                    excludingFrameIDs: overwrittenFrameIDs
                )
            )
        }

        let header = buildID3v24Header(tagSize: tagFrames.count)

        data = Data()
        data.append(header)
        data.append(tagFrames)
        data.append(audioBody)

        try AtomicFileWriter.write(data, to: fileURL)
    }

    /// Frame IDs this editor writes itself, so they aren't duplicated when
    /// preserving the remaining frames from the original tag.
    private static let overwrittenFrameIDs: Set<String> = [
        "TIT2", "TPE1", "TALB", "TCON", "TKEY", "TBPM", "TYER", "TDRC", "TDAT", "COMM"
    ]

    private static func buildID3v24Header(tagSize: Int) -> Data {
        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33]) // ID3
        header.append(0x04) // version 2.4
        header.append(0x00) // revision
        header.append(0x00) // flags
        header.append(contentsOf: encodeSyncSafeInt(tagSize))
        return header
    }

    private static func buildID3v24Frames(metadata: SeratoTrackMetadataUpdate) -> Data {
        var frames = Data()

        frames.append(makeTextFrame(id: "TIT2", value: metadata.title))
        frames.append(makeTextFrame(id: "TPE1", value: metadata.artist))
        frames.append(makeTextFrame(id: "TALB", value: metadata.album))
        frames.append(makeTextFrame(id: "TCON", value: metadata.genre))
        frames.append(makeTextFrame(id: "TKEY", value: metadata.key))
        frames.append(makeTextFrame(id: "TBPM", value: metadata.bpm.map { String(format: "%.0f", $0) } ?? ""))
        frames.append(makeTextFrame(id: "TYER", value: metadata.year.map(String.init) ?? ""))
        frames.append(makeCommentFrame(value: metadata.comment))

        return frames
    }

    private static func makeTextFrame(id: String, value: String) -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Data() }

        var payload = Data([0x03]) // UTF-8
        payload.append(trimmed.data(using: .utf8) ?? Data())

        var frame = Data(id.utf8)
        frame.append(contentsOf: encodeSyncSafeInt(payload.count))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private static func makeCommentFrame(value: String) -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Data() }

        var payload = Data([0x03]) // UTF-8
        payload.append(contentsOf: [0x65, 0x6E, 0x67]) // language: eng
        payload.append(0x00) // empty description terminator
        payload.append(trimmed.data(using: .utf8) ?? Data())

        var frame = Data("COMM".utf8)
        frame.append(contentsOf: encodeSyncSafeInt(payload.count))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private static func encodeSyncSafeInt(_ value: Int) -> [UInt8] {
        let v = max(0, value)
        return [
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F)
        ]
    }

    private static func decodeSyncSafeInt(_ bytes: [UInt8]) -> Int {
        guard bytes.count == 4 else { return 0 }
        return (Int(bytes[0] & 0x7F) << 21)
            | (Int(bytes[1] & 0x7F) << 14)
            | (Int(bytes[2] & 0x7F) << 7)
            | Int(bytes[3] & 0x7F)
    }

    private static func storedPathCandidates(track: Track, rootDirectory: URL, databaseData: Data) -> [String] {
        var candidates: [String] = [track.seratoStoredPath]

        let derived = SeratoLibraryLocator.seratoStoredPath(for: track.fileURL, rootDirectory: rootDirectory)
        if !derived.isEmpty, !candidates.contains(derived) {
            candidates.append(derived)
        }

        let canonicalTargetPaths = canonicalPathSet(for: track.fileURL)
        for chunk in SeratoChunkCodec.readChunks(from: databaseData) where chunk.tag == "otrk" {
            let fields = SeratoChunkCodec.readChunks(from: chunk.payload)
            guard let pfil = fields.first(where: { $0.tag == "pfil" }) else { continue }
            let storedPath = SeratoChunkCodec.decodeUTF16BEString(pfil.payload)
            let resolved = SeratoLibraryLocator.resolve(seratoStoredPath: storedPath, rootDirectory: rootDirectory)
            if canonicalTargetPaths.contains(canonicalPath(for: resolved)), !candidates.contains(storedPath) {
                candidates.append(storedPath)
            }
        }

        return candidates
    }

    private static func verifyPersistedMetadata(
        _ metadata: SeratoTrackMetadataUpdate,
        in databaseData: Data,
        rootDirectory: URL,
        fileURL: URL
    ) -> Bool {
        let canonicalTargetPaths = canonicalPathSet(for: fileURL)
        let tracks = SeratoDatabaseParser.parseTracks(from: databaseData, rootDirectory: rootDirectory)

        guard let persistedTrack = tracks.first(where: { canonicalTargetPaths.contains(canonicalPath(for: $0.fileURL)) }) else {
            return false
        }

        return normalizedEquals(expected: metadata.title, actual: persistedTrack.title)
            && normalizedEquals(expected: metadata.artist, actual: persistedTrack.artist)
            && normalizedEquals(expected: metadata.album, actual: persistedTrack.album)
            && normalizedEquals(expected: metadata.genre, actual: persistedTrack.genre)
            && normalizedEquals(expected: metadata.comment, actual: persistedTrack.comment)
            && normalizedOptionalEquals(expected: metadata.key, actual: persistedTrack.key)
            && normalizedNumericEquals(expected: metadata.bpm, actual: persistedTrack.bpm)
            && metadata.year == persistedTrack.year
    }

    private static func normalizedEquals(expected: String, actual: String) -> Bool {
        expected.trimmingCharacters(in: .whitespacesAndNewlines)
            == actual.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptionalEquals(expected: String, actual: String?) -> Bool {
        expected.trimmingCharacters(in: .whitespacesAndNewlines)
            == (actual ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedNumericEquals(expected: Double?, actual: Double?) -> Bool {
        switch (expected, actual) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // BPM is persisted as a rounded integer string, so the readback can
            // differ from the requested value by up to 0.5. Compare with a
            // tolerance instead of rounding both sides (which disagreed for
            // half values and produced false verification failures).
            return abs(lhs - rhs) < 1.0
        default:
            return false
        }
    }

    private static func canonicalPathSet(for fileURL: URL) -> Set<String> {
        [
            canonicalPath(for: fileURL),
            canonicalPath(for: fileURL.standardizedFileURL),
            canonicalPath(for: fileURL.resolvingSymlinksInPath().standardizedFileURL)
        ]
    }

    private static func canonicalPath(for fileURL: URL) -> String {
        var path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    private static func firstMatchingStoredPath(candidates: [String], in databaseData: Data) -> String? {
        let existingPaths = Set(
            SeratoChunkCodec.readChunks(from: databaseData)
                .filter { $0.tag == "otrk" }
                .compactMap { trackChunk -> String? in
                    let fields = SeratoChunkCodec.readChunks(from: trackChunk.payload)
                    guard let pfil = fields.first(where: { $0.tag == "pfil" }) else { return nil }
                    return SeratoChunkCodec.decodeUTF16BEString(pfil.payload)
                }
        )

        return candidates.first(where: { existingPaths.contains($0) })
    }

    private static func proposedRenamedFileURL(for fileURL: URL, metadata: SeratoTrackMetadataUpdate) -> URL? {
        let artist = sanitizeFilenameComponent(metadata.artist)
        let title = sanitizeFilenameComponent(metadata.title)
        let album = sanitizeFilenameComponent(metadata.album)
        let year = metadata.year.map(String.init).map(sanitizeFilenameComponent) ?? ""
        let genre = sanitizeFilenameComponent(metadata.genre)

        let components = [artist, title, album, year, genre].filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        let baseName = components.joined(separator: "-")
        let ext = fileURL.pathExtension
        var candidate = fileURL.deletingLastPathComponent().appendingPathComponent(baseName)
        if !ext.isEmpty {
            candidate.appendPathExtension(ext)
        }

        return uniqueFileURL(candidate)
    }

    private static func uniqueFileURL(_ preferred: URL) -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }

        let ext = preferred.pathExtension
        let base = preferred.deletingPathExtension().lastPathComponent
        let directory = preferred.deletingLastPathComponent()
        var index = 2

        while true {
            var candidate = directory.appendingPathComponent("\(base) (\(index))")
            if !ext.isEmpty {
                candidate.appendPathExtension(ext)
            }
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private static func sanitizeFilenameComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = trimmed.unicodeScalars.map { scalar -> Character in
            if forbidden.contains(scalar) || scalar.value < 32 {
                return "-"
            }
            return Character(scalar)
        }

        var normalized = String(cleaned)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while normalized.contains("--") {
            normalized = normalized.replacingOccurrences(of: "--", with: "-")
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
    }

    private static func rewriteCratesPath(
        oldStoredPath: String,
        newStoredPath: String,
        libraryDirectory: URL
    ) throws {
        guard oldStoredPath != newStoredPath else { return }

        // Smart crates (.scrate) contain rule payloads that must not be
        // regenerated via the plain crate writer, or their logic is lost.
        let entries = SeratoLibraryLocator.subcrateFiles(in: libraryDirectory)

        for entry in entries {
            let crateURL = entry.url
            let crateData = try Data(contentsOf: crateURL)
            let paths = SeratoCrateParser.trackPaths(from: crateData)
            guard paths.contains(oldStoredPath) else { continue }

            let rewrittenPaths = paths.map { $0 == oldStoredPath ? newStoredPath : $0 }
            try SeratoBackupBeforeWrite.snapshot(of: crateURL)
            let rewrittenData = SeratoCrateWriter.makeCrateData(trackPaths: rewrittenPaths)
            try AtomicFileWriter.write(rewrittenData, to: crateURL)
        }
    }
}
