// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation

/// Repairs MP3s that older EZLibrary versions tagged with a `TYER` year frame
/// inside an ID3v2.4 tag. `TYER` only exists in v2.3 (v2.4 uses `TDRC`), so
/// Serato ignored the year. The fix renames the frame ID in place — both IDs
/// are four bytes and carry the same text payload, so nothing else in the file
/// moves or is re-encoded. Genuine v2.3 tags are left alone.
public enum ID3YearTagRepair {
    public enum Outcome: Sendable, Equatable {
        case repaired
        /// Nothing to do: not an MP3, not a v2.4 tag, or no `TYER` frame.
        case notNeeded
        /// A `TDRC` already exists, so the stray `TYER` was left untouched.
        case alreadyHasTDRC
    }

    public enum RepairError: LocalizedError {
        case verificationFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .verificationFailed(name):
                return "The year tag in \(name) didn't read back correctly after repair, so the original was kept."
            }
        }
    }

    /// Whether `fileURL` needs repair, without modifying it.
    public static func needsRepair(fileURL: URL) -> Bool {
        guard fileURL.pathExtension.lowercased() == "mp3",
              let tag = ID3ArtworkCodec.readID3TagBytes(at: fileURL) else { return false }
        guard let found = locateFrames(in: tag) else { return false }
        return found.tyer != nil && !found.hasTDRC
    }

    @discardableResult
    public static func repair(fileURL: URL) throws -> Outcome {
        guard fileURL.pathExtension.lowercased() == "mp3" else { return .notNeeded }

        var data = try Data(contentsOf: fileURL)
        guard let found = locateFrames(in: data), let tyerOffset = found.tyer else {
            return .notNeeded
        }
        if found.hasTDRC { return .alreadyHasTDRC }

        data.replaceSubrange(tyerOffset..<tyerOffset + 4, with: Data("TDRC".utf8))
        try AtomicFileWriter.write(data, to: fileURL)

        let written = try Data(contentsOf: fileURL)
        guard written == data,
              let after = locateFrames(in: written), after.hasTDRC, after.tyer == nil else {
            throw RepairError.verificationFailed(fileURL.lastPathComponent)
        }
        return .repaired
    }

    /// Repairs every file that needs it, collecting failures instead of
    /// stopping at the first one.
    public static func repair(fileURLs: [URL]) -> (repaired: Int, failures: [(URL, Error)]) {
        var repaired = 0
        var failures: [(URL, Error)] = []
        for url in fileURLs {
            do {
                if try repair(fileURL: url) == .repaired { repaired += 1 }
            } catch {
                failures.append((url, error))
            }
        }
        return (repaired, failures)
    }

    // MARK: - Frame scan

    private struct Located {
        var tyer: Int?
        var hasTDRC = false
    }

    /// Walks the v2.4 frame headers of the leading ID3 tag, returning the byte
    /// offset of a `TYER` frame ID and whether a `TDRC` frame exists.
    private static func locateFrames(in data: Data) -> Located? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              bytes[3] == 0x04 else { return nil }

        let flags = bytes[5]
        let end = min(data.count, 10 + syncSafe(bytes[6..<10]))
        var pos = 10
        if flags & 0x40 != 0 { // extended header (size is sync-safe in v2.4)
            guard pos + 4 <= end else { return nil }
            pos += syncSafe(data[pos..<pos + 4])
        }

        var result = Located()
        while pos + 10 <= end {
            if data[pos] == 0x00 { break } // padding
            let id = String(decoding: data[pos..<pos + 4], as: UTF8.self)
            let size = syncSafe(data[pos + 4..<pos + 8])
            guard size > 0, pos + 10 + size <= end else { break }
            if id == "TYER", result.tyer == nil { result.tyer = pos }
            if id == "TDRC" { result.hasTDRC = true }
            pos += 10 + size
        }
        return result
    }

    private static func syncSafe<S: Sequence>(_ bytes: S) -> Int where S.Element == UInt8 {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }
}
