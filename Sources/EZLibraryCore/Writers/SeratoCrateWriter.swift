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

/// Builds new `.crate` file contents from scratch (e.g. for a "Missing
/// Tracks" review crate). Not intended for editing an existing crate file in
/// place — that should be done surgically like `SeratoDatabaseWriter`, once a
/// feature needs it, to avoid dropping fields this codebase doesn't parse.
public enum SeratoCrateWriter {
    /// The version string Serato itself writes into new crate files,
    /// confirmed against a real `.crate` file's bytes.
    private static let versionString = "1.0/Serato ScratchLive Crate"

    /// A single default "song" column, matching what Serato writes for a
    /// freshly created crate.
    private static let defaultColumns: [(name: String, width: String)] = [("song", "250")]

    /// Rewrites the `ptrk` path inside every `otrk` record whose current path
    /// is a key in `pathMap`, copying every other chunk through byte for byte.
    ///
    /// Unlike `makeCrateData`, this is safe on a `.scrate`: smart crates carry
    /// their rule definitions (`rart`/`rlut`/`rurt`) and column layout
    /// alongside a *materialized* list of member paths, and regenerating one
    /// from paths alone throws the rules away. Skipping smart crates instead
    /// was worse — Serato re-imports a stale path from them and re-adds the
    /// renamed track as a second, missing entry.
    public static func rewritingTrackPaths(
        _ pathMap: [String: String],
        in fileData: Data
    ) -> (data: Data, rewrittenCount: Int) {
        guard !pathMap.isEmpty else { return (fileData, 0) }

        var rewrittenCount = 0
        let chunks = SeratoChunkCodec.readChunks(from: fileData)

        let newChunks: [SeratoChunk] = chunks.map { chunk in
            guard chunk.tag == "otrk" else { return chunk }
            let fields = SeratoChunkCodec.readChunks(from: chunk.payload)
            guard
                let ptrk = fields.first(where: { $0.tag == "ptrk" }),
                let newPath = pathMap[SeratoChunkCodec.decodeUTF16BEString(ptrk.payload)]
            else {
                return chunk
            }

            rewrittenCount += 1
            let newFields = fields.map { field -> SeratoChunk in
                guard field.tag == "ptrk" else { return field }
                return SeratoChunk(tag: "ptrk", payload: SeratoChunkCodec.encodeUTF16BEString(newPath))
            }
            return SeratoChunk(tag: "otrk", payload: SeratoChunkCodec.writeChunks(newFields))
        }

        return (SeratoChunkCodec.writeChunks(newChunks), rewrittenCount)
    }

    public static func makeCrateData(trackPaths: [String]) -> Data {
        var chunks: [SeratoChunk] = [
            SeratoChunk(tag: "vrsn", payload: SeratoChunkCodec.encodeUTF16BEString(versionString))
        ]

        for column in defaultColumns {
            let ovctFields: [SeratoChunk] = [
                SeratoChunk(tag: "tvcn", payload: SeratoChunkCodec.encodeUTF16BEString(column.name)),
                SeratoChunk(tag: "tvcw", payload: SeratoChunkCodec.encodeUTF16BEString(column.width))
            ]
            chunks.append(SeratoChunk(tag: "ovct", payload: SeratoChunkCodec.writeChunks(ovctFields)))
        }

        for trackPath in trackPaths {
            let ptrk = SeratoChunk(tag: "ptrk", payload: SeratoChunkCodec.encodeUTF16BEString(trackPath))
            chunks.append(SeratoChunk(tag: "otrk", payload: SeratoChunkCodec.writeChunk(ptrk)))
        }

        return SeratoChunkCodec.writeChunks(chunks)
    }
}
