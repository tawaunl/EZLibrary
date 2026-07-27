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

/// Parses a single Serato `.crate` file: a `vrsn` header, `ovct`
/// column-view metadata, and one `otrk` chunk per track containing a
/// nested `ptrk` (track path) field.
///
/// Field tags cross-checked against Mixxx's open-source Serato crate
/// reader (`src/library/serato/seratofeature.cpp`).
///
/// Performance: a full library load parses every crate file, so the hot path
/// scans each file's chunks by byte offset rather than building
/// `[SeratoChunk]` — the old path allocated a `Data` copy and a tag `String`
/// per `otrk`, then a second array per record, which across a few hundred
/// crates was the largest remaining cost in `LibraryService.reload`.
public enum SeratoCrateParser {
    public enum ParserError: Error {
        case fileNotFound(URL)
    }

    public static func parseCrate(at fileURL: URL) throws -> Crate {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound(fileURL)
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return Crate(
            pathComponents: Crate.pathComponents(forCrateFileNamed: baseName),
            trackPaths: trackPaths(from: data),
            fileURL: fileURL
        )
    }

    public static func trackPaths(from data: Data) -> [String] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String] in
            guard raw.baseAddress != nil else { return [] }
            let count = raw.count
            var paths: [String] = []
            var offset = 0
            while offset + 8 <= count {
                let tag = SeratoChunkCodec.readTag(raw, offset)
                let size = SeratoChunkCodec.readSize(raw, offset + 4)
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + size
                // Trailing bytes that don't form a complete chunk are ignored
                // rather than treated as an error, matching `readChunks`.
                guard payloadEnd <= count else { break }
                if tag == tagOtrk,
                   let path = trackPath(raw: raw, start: payloadStart, end: payloadEnd) {
                    paths.append(path)
                }
                offset = payloadEnd
            }
            return paths
        }
    }

    /// Returns the first `ptrk` field in one `otrk` payload, or `nil` for a
    /// record that carries no track path (which the caller drops).
    private static func trackPath(
        raw: UnsafeRawBufferPointer,
        start: Int,
        end: Int
    ) -> String? {
        var offset = start
        while offset + 8 <= end {
            let tag = SeratoChunkCodec.readTag(raw, offset)
            let size = SeratoChunkCodec.readSize(raw, offset + 4)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }
            if tag == tagPtrk {
                return SeratoChunkCodec.decodeUTF16BE(raw, payloadStart..<payloadEnd)
            }
            offset = payloadEnd
        }
        return nil
    }

    private static let tagOtrk = SeratoChunkCodec.fourCC("otrk")
    private static let tagPtrk = SeratoChunkCodec.fourCC("ptrk")
}
