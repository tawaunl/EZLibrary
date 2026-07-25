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

/// Decides what a duplicate deletion is allowed to touch on disk.
///
/// Extracted from the view so the rules that decide which files get trashed
/// are testable. This is the most destructive path in the app, and the
/// decisions here are the ones that can't be undone from the app.
public enum DuplicateDeletionPlanner {
    public enum Blocker: Error, LocalizedError, Sendable, Equatable {
        case seratoIsRunning

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ before deleting duplicates. Nothing was changed."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato rewrites its library on quit, which would undo these edits or clobber the files mid-write."
            }
        }
    }

    /// Why the deletion must not start, or nil when it's safe to proceed.
    ///
    /// Checked *before* anything is trashed. The crate writer refuses to run
    /// while Serato is open, and when that refusal happened after the files
    /// were already in the Trash, the library was left pointing at them.
    public static func blocker(seratoIsRunning: Bool = SeratoProcessGuard.isSeratoRunning) -> Blocker? {
        seratoIsRunning ? .seratoIsRunning : nil
    }

    /// Files that may be moved to the Trash, in the order given.
    ///
    /// - Parameters:
    ///   - deletedTracks: Library entries being removed.
    ///   - survivingTracks: Every library entry that remains afterward.
    ///
    /// Excludes any file a surviving entry still points at — a library can
    /// hold two entries for one file, and trashing it would break the entry
    /// the user chose to keep. Also skips files already gone, and never
    /// returns the same file twice.
    public static func filesToTrash(
        deletedTracks: [Track],
        survivingTracks: [Track],
        fileManager: FileManager = .default
    ) -> [URL] {
        let retained = Set(survivingTracks.map { $0.fileURL.standardizedFileURL.path })

        var seen = Set<String>()
        var result: [URL] = []
        for track in deletedTracks {
            let path = track.fileURL.standardizedFileURL.path
            guard !retained.contains(path) else { continue }
            guard fileManager.fileExists(atPath: path) else { continue }
            guard seen.insert(path).inserted else { continue }
            result.append(track.fileURL)
        }
        return result
    }

    /// Library entries left after `deletedPaths` are removed.
    public static func survivingTracks(in allTracks: [Track], deletedPaths: Set<String>) -> [Track] {
        allTracks.filter { !deletedPaths.contains($0.seratoStoredPath) }
    }
}
