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

/// Fast case-insensitive substring search across a track's textual fields.
///
/// `String.contains` / `localizedCaseInsensitiveContains` spend most of their
/// time on Unicode grapheme segmentation, which dominated the table/scope
/// search on large libraries. This compares lowercased UTF-8 bytes instead,
/// which cut a search keystroke over 50K tracks from ~60ms to well under 30ms
/// (measured via `EZLibraryBench`).
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
        var combined = track.title
        combined.append("\u{01}")
        combined.append(track.artist)
        combined.append("\u{01}")
        combined.append(track.album)
        combined.append("\u{01}")
        combined.append(track.genre)
        if includeFileName {
            combined.append("\u{01}")
            combined.append(track.fileURL.lastPathComponent)
        }
        return Array(combined.lowercased().utf8)
    }

    /// The lowercased UTF-8 bytes of a search query (trimmed). An empty result
    /// means "match everything".
    public static func needle(for query: String) -> [UInt8] {
        Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    /// Whether prebuilt `bytes` (from `searchBytes(for:)`) contain `needle`.
    /// An empty needle matches everything.
    public static func matches(bytes: [UInt8], needle: [UInt8]) -> Bool {
        needle.isEmpty || bytesContain(bytes, needle)
    }

    /// Plain byte substring search. `needle` must be non-empty.
    static func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let first = needle[0]
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
