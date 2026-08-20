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

// The Mac-side half of snapshot handling: producing one from a parsed library,
// and writing it through the same atomic-write machinery every other library
// write uses. Encoding, decoding, naming, and reading live in
// `EZLibrarySnapshotKit` so a phone can do them without any of this.
extension LibrarySnapshotBuilder {
    /// Captures the parsed library as a portable snapshot.
    ///
    /// Smart crates can be included so a remote device can display them, but
    /// they are read-only there: their contents are a Serato query result, not
    /// a stored membership list.
    public static func makeSnapshot(
        tracks: [Track],
        crates: [Crate],
        libraryDirectory: URL,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default
    ) -> LibrarySnapshot {
        LibrarySnapshot(
            generatedAt: generatedAt,
            libraryFingerprint: LibraryFingerprint.compute(
                libraryDirectory: libraryDirectory,
                fileManager: fileManager
            ),
            tracks: tracks.map(SnapshotTrack.init(track:)),
            crates: crates.map(SnapshotCrate.init(crate:))
        )
    }

    @discardableResult
    public static func write(
        _ snapshot: LibrarySnapshot,
        toDirectory directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: snapshot))
        try AtomicFileWriter.write(try encode(snapshot), to: url)
        return url
    }
}
