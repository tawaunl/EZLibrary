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
import EZLibrarySnapshotKit

/// Fast case-insensitive substring search across a track's textual fields.
///
/// The byte matcher itself lives in `ByteTextSearch` so that this and the
/// snapshot-side `SnapshotTrackSearch` a phone uses are literally the same
/// code — a search that ranked differently per device would be worse than a
/// slow one. See `ByteTextSearch` for why bytes rather than `String.contains`.
public enum TrackTextSearch {
    /// Returns the tracks whose title, artist, album, or genre — plus the file
    /// name when `includeFileName` is set — contain `query`, case-insensitively.
    /// An empty or whitespace-only query returns `tracks` unchanged.
    public static func filter(_ tracks: [Track], query: String, includeFileName: Bool = false) -> [Track] {
        let needle = needle(for: query)
        guard !needle.isEmpty else { return tracks }
        return tracks.filter { matches($0, needle: needle, includeFileName: includeFileName) }
    }

    /// Whether one track's searchable text contains an already-lowercased
    /// UTF-8 `needle`. Callers doing their own iteration should build `needle`
    /// once (`needle(for:)`) and reuse it across tracks.
    public static func matches(_ track: Track, needle: [UInt8], includeFileName: Bool) -> Bool {
        matches(bytes: searchBytes(for: track, includeFileName: includeFileName), needle: needle)
    }

    /// The lowercased UTF-8 search "blob" for a track: title, artist, album,
    /// and genre (and file name when requested) joined by a control-byte
    /// separator that keeps a query from matching across two fields. Build
    /// these once and cache them to search repeatedly without re-lowercasing.
    public static func searchBytes(for track: Track, includeFileName: Bool = false) -> [UInt8] {
        var fields = [track.title, track.artist, track.album, track.genre]
        if includeFileName {
            fields.append(track.fileURL.lastPathComponent)
        }
        return ByteTextSearch.searchBytes(fields: fields)
    }

    /// The lowercased UTF-8 bytes of a search query (trimmed). An empty result
    /// means "match everything".
    public static func needle(for query: String) -> [UInt8] {
        ByteTextSearch.needle(for: query)
    }

    /// Whether prebuilt `bytes` (from `searchBytes(for:)`) contain `needle`.
    /// An empty needle matches everything.
    public static func matches(bytes: [UInt8], needle: [UInt8]) -> Bool {
        ByteTextSearch.matches(bytes: bytes, needle: needle)
    }

    /// Plain byte substring search. `needle` must be non-empty.
    static func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        ByteTextSearch.bytesContain(haystack, needle)
    }
}
