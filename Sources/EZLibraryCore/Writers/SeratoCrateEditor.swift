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

/// Safe crate file mutations (create/update track membership) that never touch
/// audio files themselves.
public enum SeratoCrateEditor {
    public enum EditError: LocalizedError {
        case seratoIsRunning
        case missingCrateFileURL

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running. Quit Serato before changing crates so it doesn't overwrite the changes."
            case .missingCrateFileURL:
                return "That crate has no file on disk, so its track list can't be changed."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its crates from memory on quit, which would revert this change."
            case .missingCrateFileURL:
                return "Reload the library and try again. If the crate still has no file, recreate it."
            }
        }
    }

    /// Creates a new crate file under `destinationFileURL`.
    public static func createCrate(
        at destinationFileURL: URL,
        trackPaths: [String] = []
    ) throws {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }

        let uniqueTrackPaths = uniquedPreservingOrder(trackPaths)
        let data = SeratoCrateWriter.makeCrateData(trackPaths: uniqueTrackPaths)
        try AtomicFileWriter.write(data, to: destinationFileURL)
    }

    /// Rewrites one existing crate's track membership.
    @discardableResult
    public static func rewriteTrackPaths(
        in crate: Crate,
        to trackPaths: [String]
    ) throws -> Crate {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }
        guard let fileURL = crate.fileURL else {
            throw EditError.missingCrateFileURL
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: fileURL)
        }

        let uniqueTrackPaths = uniquedPreservingOrder(trackPaths)
        let data = SeratoCrateWriter.makeCrateData(trackPaths: uniqueTrackPaths)
        try AtomicFileWriter.write(data, to: fileURL)

        var updated = crate
        updated.trackPaths = uniqueTrackPaths
        return updated
    }

    private static func uniquedPreservingOrder(_ trackPaths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in trackPaths {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }
}
