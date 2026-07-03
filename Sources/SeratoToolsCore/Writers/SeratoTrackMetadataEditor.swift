import Foundation

/// Applies track metadata edits to both Serato `database V2` and audio file
/// ID3 tags (for MP3 files).
public enum SeratoTrackMetadataEditor {
    public enum EditError: Error, LocalizedError {
        case seratoIsRunning
        case trackNotFoundInDatabase(String)
        case fileTypeNotSupportedForID3(URL)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato appears to be running. Close Serato and try saving metadata again."
            case let .trackNotFoundInDatabase(path):
                return "Could not find this track in database V2 for path: \(path)"
            case let .fileTypeNotSupportedForID3(fileURL):
                return "ID3 writing is only supported for MP3 files. Unsupported file: \(fileURL.lastPathComponent)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry the save."
            case .trackNotFoundInDatabase:
                return "Reload the library and retry. If it still fails, the track path in database V2 may have changed."
            case .fileTypeNotSupportedForID3:
                return "Metadata can still be written to Serato database V2 for this track type."
            }
        }
    }

    public static func update(
        track: Track,
        metadata: SeratoTrackMetadataUpdate,
        databaseFileURL: URL
    ) throws {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }

        // Update on-disk ID3 first so we never commit DB-only edits when a
        // file-tag write fails.
        try writeID3IfSupported(fileURL: track.fileURL, metadata: metadata)

        if FileManager.default.fileExists(atPath: databaseFileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        }

        let original = try Data(contentsOf: databaseFileURL)
        var rewritten = SeratoDatabaseWriter.rewritingMetadata(
            forStoredPath: track.seratoStoredPath,
            metadata: metadata,
            in: original
        )

        // Fallback for path representation mismatches: derive the stored path
        // from the file URL relative to this library's root and retry once.
        if !rewritten.didRewrite {
            let libraryDirectory = databaseFileURL.deletingLastPathComponent()
            let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
            let derivedStoredPath = SeratoLibraryLocator.seratoStoredPath(
                for: track.fileURL,
                rootDirectory: rootDirectory
            )

            if derivedStoredPath != track.seratoStoredPath {
                rewritten = SeratoDatabaseWriter.rewritingMetadata(
                    forStoredPath: derivedStoredPath,
                    metadata: metadata,
                    in: original
                )
            }
        }

        guard rewritten.didRewrite else {
            throw EditError.trackNotFoundInDatabase(track.seratoStoredPath)
        }

        try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)
    }

    private static func writeID3IfSupported(fileURL: URL, metadata: SeratoTrackMetadataUpdate) throws {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "mp3" else {
            return
        }

        var data = try Data(contentsOf: fileURL)
        let audioBody: Data

        if data.count >= 10, String(data: data.prefix(3), encoding: .ascii) == "ID3" {
            let size = decodeSyncSafeInt(Array(data[6...9]))
            let end = min(data.count, 10 + size)
            audioBody = data.subdata(in: end..<data.count)
        } else {
            audioBody = data
        }

        let tagFrames = buildID3v24Frames(metadata: metadata)
        let header = buildID3v24Header(tagSize: tagFrames.count)

        data = Data()
        data.append(header)
        data.append(tagFrames)
        data.append(audioBody)

        try AtomicFileWriter.write(data, to: fileURL)
    }

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
}
