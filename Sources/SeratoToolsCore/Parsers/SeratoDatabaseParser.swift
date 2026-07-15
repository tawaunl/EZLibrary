import Foundation

/// Parses Serato's binary `database V2` track database format: a flat
/// sequence of tagged chunks (see `SeratoChunkCodec`), where each `otrk`
/// chunk is itself a nested sequence of per-field chunks.
///
/// Field tags below were cross-checked against Mixxx's open-source Serato
/// database reader (`src/library/serato/seratofeature.cpp`).
public enum SeratoDatabaseParser {
    public enum ParserError: Error {
        case fileNotFound(URL)
    }

    /// Parses every `otrk` record in `fileURL`, resolving each track's
    /// stored path against `rootDirectory` (see
    /// `SeratoLibraryLocator.rootDirectory`).
    public static func parseTracks(at fileURL: URL, rootDirectory: URL) throws -> [Track] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound(fileURL)
        }
        let data = try Data(contentsOf: fileURL)
        return parseTracks(from: data, rootDirectory: rootDirectory)
    }

    public static func parseTracks(from data: Data, rootDirectory: URL) -> [Track] {
        SeratoChunkCodec.readChunks(from: data)
            .filter { $0.tag == "otrk" }
            .compactMap { track(from: $0.payload, rootDirectory: rootDirectory) }
    }

    private static func track(from payload: Data, rootDirectory: URL) -> Track? {
        // One pass into a dictionary (first occurrence wins, matching the
        // previous `first(where:)` behavior) instead of a linear scan of
        // `fields` per looked-up tag — this runs once per track on load.
        var fields: [String: Data] = [:]
        for chunk in SeratoChunkCodec.readChunks(from: payload) where fields[chunk.tag] == nil {
            fields[chunk.tag] = chunk.payload
        }
        guard let seratoStoredPath = string(in: fields, tag: "pfil"), !seratoStoredPath.isEmpty else {
            // Serato uses the file path as the track's identity; a record
            // without one can't be referenced by crates and is unusable.
            return nil
        }

        return Track(
            seratoStoredPath: seratoStoredPath,
            fileURL: SeratoLibraryLocator.resolve(seratoStoredPath: seratoStoredPath, rootDirectory: rootDirectory),
            title: string(in: fields, tag: "tsng") ?? "",
            artist: string(in: fields, tag: "tart") ?? "",
            album: string(in: fields, tag: "talb") ?? "",
            genre: string(in: fields, tag: "tgen") ?? "",
            comment: string(in: fields, tag: "tcom") ?? "",
            grouping: string(in: fields, tag: "tgrp") ?? "",
            label: string(in: fields, tag: "tlbl") ?? "",
            year: string(in: fields, tag: "ttyr").flatMap { Int($0) },
            duration: string(in: fields, tag: "tlen").flatMap { TimeInterval($0) },
            bitrate: string(in: fields, tag: "tbit"),
            sampleRate: string(in: fields, tag: "tsmp"),
            bpm: string(in: fields, tag: "tbpm").flatMap { Double($0) },
            key: string(in: fields, tag: "tkey"),
            trackNumber: uint16(in: fields, tag: "utkn").map(Int.init),
            colorCode: colorValue(in: fields, tag: "ulbl"),
            isBeatgridLocked: bool(in: fields, tag: "bbgl"),
            isMissing: bool(in: fields, tag: "bmis"),
            dateAdded: uint32(in: fields, tag: "uadd").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func string(in fields: [String: Data], tag: String) -> String? {
        fields[tag].map(SeratoChunkCodec.decodeUTF16BEString)
    }

    private static func bool(in fields: [String: Data], tag: String) -> Bool {
        guard let byte = fields[tag]?.first else {
            return false
        }
        return byte != 0
    }

    private static func uint32(in fields: [String: Data], tag: String) -> UInt32? {
        guard let payload = fields[tag], payload.count == 4 else {
            return nil
        }
        return payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
        }
    }

    private static func uint16(in fields: [String: Data], tag: String) -> UInt16? {
        guard let payload = fields[tag], payload.count == 2 else {
            return nil
        }
        return payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            (UInt16(raw[0]) << 8) | UInt16(raw[1])
        }
    }

    private static func colorValue(in fields: [String: Data], tag: String) -> UInt32? {
        guard let value = uint32(in: fields, tag: tag) else {
            return nil
        }
        // Serato uses 0x00FFFFFF for "no color".
        return value == 0x00FF_FFFF ? nil : value
    }
}
