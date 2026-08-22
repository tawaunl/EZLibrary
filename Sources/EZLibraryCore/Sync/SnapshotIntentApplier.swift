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

/// Applies a resolved incoming change to the real Serato library, reusing the
/// same guarded, backed-up, verified write paths the desktop UI uses. Never
/// renames audio files from a remote edit — a phone tag change should not move
/// files on the Mac behind the user's back.
public enum SnapshotIntentApplier {
    public enum ApplyError: LocalizedError {
        case seratoIsRunning
        case trackNotFound(String)
        case crateNotFound

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running, so incoming changes can't be applied."
            case let .trackNotFound(path):
                return "The track for this change couldn't be found: \(path)"
            case .crateNotFound:
                return "The crate for this change couldn't be found on disk."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then apply again."
            case .trackNotFound, .crateNotFound:
                return "Reload the library and try again."
            }
        }
    }

    public static func apply(
        _ change: ResolvedOperation,
        tracks: [Track],
        crates: [Crate],
        libraryDirectory: URL
    ) throws {
        switch change {
        case let .editTrackField(storedPath, field, newValue, _):
            try applyFieldEdit(
                storedPath: storedPath, field: field, newValue: newValue,
                tracks: tracks, libraryDirectory: libraryDirectory
            )
        case let .createCrate(pathComponents):
            try applyCreateCrate(pathComponents: pathComponents, libraryDirectory: libraryDirectory)
        case let .renameCrate(fromPathComponents, newName):
            try applyRenameCrate(from: fromPathComponents, newName: newName, crates: crates)
        case let .deleteCrate(pathComponents):
            try applyDeleteCrate(pathComponents: pathComponents, crates: crates)
        }
    }

    // MARK: - Track field edit

    private static func applyFieldEdit(
        storedPath: String,
        field: TrackField,
        newValue: String,
        tracks: [Track],
        libraryDirectory: URL
    ) throws {
        guard let track = tracks.first(where: { $0.seratoStoredPath == storedPath }) else {
            throw ApplyError.trackNotFound(storedPath)
        }
        let metadata = metadataUpdate(from: track, overriding: field, with: newValue)
        try SeratoTrackMetadataEditor.update(
            track: track,
            metadata: metadata,
            databaseFileURL: SeratoLibraryLocator.databaseFile(in: libraryDirectory),
            rewriteFilenameFromMetadata: false
        )
    }

    private static func metadataUpdate(
        from track: Track,
        overriding field: TrackField,
        with newValue: String
    ) -> SeratoTrackMetadataUpdate {
        var title = track.title
        var artist = track.artist
        var album = track.album
        var genre = track.genre
        var comment = track.comment
        var key = track.key ?? ""
        var bpm = track.bpm
        var year = track.year

        switch field {
        case .title:   title = newValue
        case .artist:  artist = newValue
        case .album:   album = newValue
        case .genre:   genre = newValue
        case .comment: comment = newValue
        case .key:     key = newValue
        case .bpm:     bpm = Double(newValue)
        case .year:    year = Int(newValue)
        }

        return SeratoTrackMetadataUpdate(
            title: title, artist: artist, album: album, genre: genre,
            comment: comment, key: key, bpm: bpm, year: year
        )
    }

    // MARK: - Crate operations

    private static func applyCreateCrate(pathComponents: [String], libraryDirectory: URL) throws {
        let baseName = Crate.fileBaseName(forPathComponents: pathComponents)
        let destination = SeratoLibraryLocator.subcratesDirectory(in: libraryDirectory)
            .appendingPathComponent(baseName)
            .appendingPathExtension("crate")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try SeratoCrateEditor.createCrate(at: destination)
    }

    private static func applyRenameCrate(from: [String], newName: String, crates: [Crate]) throws {
        guard !SeratoProcessGuard.isSeratoRunning else { throw ApplyError.seratoIsRunning }

        let affected = crates.filter { $0.pathComponents.starts(with: from) }
        guard !affected.isEmpty else { throw ApplyError.crateNotFound }

        for crate in affected {
            guard let fileURL = crate.fileURL else { continue }
            let newPath = Array(from.dropLast()) + [newName]
                + Array(crate.pathComponents.dropFirst(from.count))
            let newBaseName = Crate.fileBaseName(forPathComponents: newPath)
            let destination = fileURL.deletingLastPathComponent()
                .appendingPathComponent(newBaseName)
                .appendingPathExtension("crate")
            if fileURL == destination { continue }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try SeratoBackupBeforeWrite.snapshot(of: fileURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: destination)
        }
    }

    private static func applyDeleteCrate(pathComponents: [String], crates: [Crate]) throws {
        guard !SeratoProcessGuard.isSeratoRunning else { throw ApplyError.seratoIsRunning }

        let affected = crates.filter { $0.pathComponents.starts(with: pathComponents) }
        for crate in affected {
            guard let fileURL = crate.fileURL,
                  FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            // Trash rather than hard-delete so a mistaken remote delete is
            // recoverable from the user's Trash.
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        }
    }
}
