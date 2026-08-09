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

/// Finds tracks that aren't filed in any crate — the ones that only exist in
/// the library, easy to forget and never played.
///
/// Membership is decided on normalised paths rather than raw string equality.
/// A crate's `ptrk` entry and the database's `pfil` entry describe the same
/// file but don't always agree byte for byte on separators, a leading slash or
/// case, and a track wrongly reported as unfiled is worse than useless.
public enum UnfiledTracksService {
    /// Smart crates are excluded by default. Their membership is derived from
    /// rules and re-evaluated by Serato, so a track "in" one was never filed
    /// anywhere — which is exactly what this list is asking about. It also
    /// keeps the count consistent with the Tracks In Crates stat beside it.
    public static func filedPaths(
        in crates: [Crate],
        smartCrates: [Crate] = []
    ) -> Set<String> {
        var filed = Set<String>()
        for crate in crates {
            for path in crate.trackPaths {
                filed.insert(normalize(path))
            }
        }
        for crate in smartCrates {
            for path in crate.trackPaths {
                filed.insert(normalize(path))
            }
        }
        return filed
    }

    /// Tracks with no entry in any of `crates`, in library order.
    public static func tracksNotInAnyCrate(
        _ tracks: [Track],
        crates: [Crate],
        smartCrates: [Crate] = []
    ) -> [Track] {
        let filed = filedPaths(in: crates, smartCrates: smartCrates)
        guard !filed.isEmpty else { return tracks }
        return tracks.filter { !filed.contains(normalize($0.seratoStoredPath)) }
    }

    /// How many tracks aren't filed anywhere. Cheaper than building the list
    /// when only the badge count is needed.
    public static func countOfTracksNotInAnyCrate(
        _ tracks: [Track],
        crates: [Crate],
        smartCrates: [Crate] = []
    ) -> Int {
        let filed = filedPaths(in: crates, smartCrates: smartCrates)
        guard !filed.isEmpty else { return tracks.count }
        return tracks.reduce(into: 0) { total, track in
            if !filed.contains(normalize(track.seratoStoredPath)) { total += 1 }
        }
    }

    /// Matches the normalisation the crate-detail track resolver uses, so the
    /// two agree on whether a given crate entry refers to a given track.
    static func normalize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
