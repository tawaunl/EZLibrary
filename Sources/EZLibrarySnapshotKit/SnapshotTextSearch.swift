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

/// Case-insensitive substring matching over lowercased UTF-8 bytes.
///
/// `String.contains` / `localizedCaseInsensitiveContains` spend most of their
/// time on Unicode grapheme segmentation, which dominated search on large
/// libraries — comparing bytes cut a keystroke over 50K tracks from ~60ms to
/// well under 30ms (measured via `EZLibraryBench`).
///
/// Lives here so the Mac and a phone run the *same* matcher: two
/// reimplementations would drift, and a search that returns different results
/// on each device is worse than a slow one.
public enum ByteTextSearch {
    /// The lowercased UTF-8 bytes of a search query (trimmed). An empty result
    /// means "match everything".
    public static func needle(for query: String) -> [UInt8] {
        Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    /// Joins `fields` into one lowercased UTF-8 blob, separated by a control
    /// byte so a query cannot match across two fields (a search for
    /// "closecalvin" must not match "Feel So Close" + "Calvin Harris").
    public static func searchBytes(fields: [String]) -> [UInt8] {
        Array(fields.joined(separator: "\u{01}").lowercased().utf8)
    }

    /// Whether prebuilt `bytes` contain `needle`. An empty needle matches
    /// everything.
    public static func matches(bytes: [UInt8], needle: [UInt8]) -> Bool {
        needle.isEmpty || bytesContain(bytes, needle)
    }

    /// Plain byte substring search. `needle` must be non-empty.
    public static func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
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

/// Searching a snapshot's tracks — the phone-side counterpart to
/// `TrackTextSearch`, matching on the same fields with the same matcher.
public enum SnapshotTrackSearch {
    /// Returns the tracks whose title, artist, album, or genre — plus the file
    /// name when `includeFileName` is set — contain `query`,
    /// case-insensitively. An empty or whitespace-only query returns `tracks`
    /// unchanged.
    public static func filter(
        _ tracks: [SnapshotTrack],
        query: String,
        includeFileName: Bool = false
    ) -> [SnapshotTrack] {
        let needle = ByteTextSearch.needle(for: query)
        guard !needle.isEmpty else { return tracks }
        return tracks.filter {
            ByteTextSearch.matches(
                bytes: searchBytes(for: $0, includeFileName: includeFileName),
                needle: needle
            )
        }
    }

    /// The lowercased UTF-8 search blob for one snapshot track. Build these
    /// once and cache them to search repeatedly without re-lowercasing —
    /// which is what a phone typing into a search field should do.
    public static func searchBytes(for track: SnapshotTrack, includeFileName: Bool = false) -> [UInt8] {
        var fields = [track.title, track.artist, track.album, track.genre]
        if includeFileName {
            fields.append((track.storedPath as NSString).lastPathComponent)
        }
        return ByteTextSearch.searchBytes(fields: fields)
    }
}
