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

/// What a previous export put on the stick, kept beside the databases.
///
/// Its main job is stable ids: a CDJ caches artwork and waveforms against a
/// track's id, so an id must never change between syncs. It also records where
/// each file came from, so a later sync can reuse a copy when nothing changed
/// and remove only files this app wrote.
public struct CDJExportManifest: Codable, Equatable, Sendable {
    public struct TrackRecord: Codable, Equatable, Sendable {
        /// The Serato library path the track is identified by.
        public var key: String
        public var id: UInt32
        public var stickPath: String
        public var analyzePath: String
        public var sourceSize: Int
        public var sourceModified: Double
        public var copySize: Int
    }

    public struct PlaylistRecord: Codable, Equatable, Sendable {
        /// `p:` or `f:` (playlist or folder) followed by the crate path.
        public var key: String
        public var id: UInt32
    }

    public var version = 1
    /// The stick's own library id, written into every track row.
    public var libraryID: UInt32
    public var nextTrackID: UInt32
    public var nextPlaylistID: UInt32
    public var tracks: [TrackRecord]
    public var playlists: [PlaylistRecord]

    static func relativePath(root: String) -> String { "\(root)/CDJSeratoExport/manifest.json" }

    /// nil when the stick has no readable manifest (a first export, or a stick
    /// this app didn't write).
    static func load(from volume: URL, root: String) -> CDJExportManifest? {
        let url = volume.appendingPathComponent(relativePath(root: root))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CDJExportManifest.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}

/// Which top-level folder a stick keeps its library in. rekordbox reads both
/// spellings; a stick already holding a library keeps the one it has.
enum CDJExportRoot {
    static let candidates = ["PIONEER", ".PIONEER"]

    /// Files whose presence marks a root as already in use.
    private static let markers = ["rekordbox/export.pdb", "rekordbox/exportLibrary.db", "DEVSETTING.DAT"]

    static func select(on volume: URL, format: CDJStickFormat) throws -> String {
        let fileManager = FileManager.default
        let inUse = candidates.filter { root in
            markers.contains { fileManager.fileExists(atPath: volume.appendingPathComponent("\(root)/\($0)").path) }
        }
        if inUse.count > 1 { throw CDJExportError.conflictingRoots }
        if let existing = inUse.first { return existing }
        // A blank HFS+ volume gets the hidden spelling, as rekordbox writes it.
        return format == .hfsPlus ? ".PIONEER" : "PIONEER"
    }
}
