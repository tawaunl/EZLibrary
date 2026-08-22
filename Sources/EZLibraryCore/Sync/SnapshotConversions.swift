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
@_exported import EZLibrarySnapshotKit

// The snapshot format itself lives in `EZLibrarySnapshotKit`, which knows
// nothing about Serato's binary format and so compiles for iOS. These are the
// conversions in the other direction — from a parsed library into a snapshot —
// which only ever run on the Mac that owns the library.
//
// `@_exported` above re-exports the snapshot types to anything importing
// `EZLibraryCore`, so app and test code needs no extra import.

extension SnapshotTrack {
    public init(track: Track) {
        self.init(
            storedPath: track.seratoStoredPath,
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            comment: track.comment,
            grouping: track.grouping,
            label: track.label,
            year: track.year,
            duration: track.duration,
            bitrate: track.bitrate,
            sampleRate: track.sampleRate,
            bpm: track.bpm,
            key: track.key,
            trackNumber: track.trackNumber,
            dateAdded: track.dateAdded,
            playCount: track.playCount,
            isMissing: track.isMissing
        )
    }
}

extension SnapshotCrate {
    public init(crate: Crate) {
        self.init(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths)
    }
}
