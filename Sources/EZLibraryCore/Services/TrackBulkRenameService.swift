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

/// Renames many files from their existing tags in one pass.
///
/// Not a loop over `SeratoTrackMetadataEditor.update`: that rewrites the whole
/// `database V2`, re-scans every crate file and reopens the location database
/// per track, so renaming a few hundred tracks would redo all of it a few
/// hundred times. Each artifact is instead touched exactly once with the
/// batch-shaped primitives (`rewritingPaths`, `rewritingTrackPaths`).
///
/// Tags are not modified — only filenames, from whatever the tracks already
/// carry. Anything ambiguous is skipped and reported rather than guessed.
public enum TrackBulkRenameService {
    public enum SkipReason: Sendable, Equatable {
        /// The template renders the filename the track already has.
        case alreadyNamedCorrectly
        /// Every token in the template is empty for this track.
        case noNameFromTemplate
        /// A different file already sits at the destination.
        case destinationExists
        /// Two or more selected tracks would end up with the same name.
        case collidesWithAnotherRename
        /// The track's path isn't in `database V2`, so a rename would strand it.
        case notInDatabase
    }

    public struct Rename: Sendable, Equatable {
        public let track: Track
        public let destinationURL: URL
        public let oldStoredPath: String
        public let newStoredPath: String

        public var sourceURL: URL { track.fileURL }
    }

    public struct Skip: Sendable, Equatable {
        public let track: Track
        public let reason: SkipReason
    }

    public struct Preview: Sendable {
        public let databaseFileURL: URL
        public let rootDirectory: URL
        public let renames: [Rename]
        public let skips: [Skip]

        public var isEmpty: Bool { renames.isEmpty }
    }

    public struct Failure: Sendable {
        public let track: Track
        public let error: Error
    }

    public struct Result: Sendable {
        public let renamedCount: Int
        public let skips: [Skip]
        public let failures: [Failure]
    }

    public enum RenameError: Error, LocalizedError {
        case seratoIsRunning
        case fileMoveFailed(URL, URL, underlying: Error)
        case rollbackFailed(URL, URL)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running. Quit Serato before renaming files."
            case let .fileMoveFailed(source, destination, underlying):
                return "Could not rename \(source.lastPathComponent) to \(destination.lastPathComponent): "
                    + underlying.localizedDescription
            case let .rollbackFailed(source, destination):
                return "A rename failed and \(destination.lastPathComponent) could not be restored to "
                    + "\(source.lastPathComponent). The library was left unchanged; fix the file name by hand."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its library on quit, which would revert this."
            case .fileMoveFailed:
                return "Check file permissions and that the destination folder is writable, then retry."
            case .rollbackFailed:
                return "No library files were changed. Rename the file back manually, then retry."
            }
        }
    }

    // MARK: - Preview

    /// Works out what would be renamed. Reads only.
    public static func preview(
        tracks: [Track],
        template: String,
        databaseFileURL: URL,
        fileManager: FileManager = .default
    ) throws -> Preview {
        let libraryDirectory = databaseFileURL.deletingLastPathComponent()
        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        let storedPaths = Set(
            SeratoDatabaseParser.storedPaths(from: (try? Data(contentsOf: databaseFileURL)) ?? Data()))

        var skips: [Skip] = []
        var candidates: [(track: Track, destination: URL)] = []

        for track in tracks {
            let stem = TrackFilenameFormatter.renderStem(for: track, template: template)
            guard !stem.isEmpty else {
                skips.append(Skip(track: track, reason: .noNameFromTemplate))
                continue
            }

            let ext = track.fileURL.pathExtension
            var destination = track.fileURL.deletingLastPathComponent().appendingPathComponent(stem)
            if !ext.isEmpty { destination.appendPathExtension(ext) }

            guard destination.lastPathComponent != track.fileURL.lastPathComponent else {
                skips.append(Skip(track: track, reason: .alreadyNamedCorrectly))
                continue
            }
            guard storedPaths.contains(track.seratoStoredPath) else {
                skips.append(Skip(track: track, reason: .notInDatabase))
                continue
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                skips.append(Skip(track: track, reason: .destinationExists))
                continue
            }
            candidates.append((track, destination))
        }

        // Lowercased because the filesystem and Serato's unique index both
        // treat names case-insensitively: two destinations differing only in
        // case would each look free and the second would clobber the first.
        let claimCounts = candidates.reduce(into: [String: Int]()) { counts, candidate in
            counts[candidate.destination.standardizedFileURL.path.lowercased(), default: 0] += 1
        }

        var renames: [Rename] = []
        for candidate in candidates {
            let key = candidate.destination.standardizedFileURL.path.lowercased()
            // Every track wanting a contested name is skipped, not just the
            // losers — picking a winner would be arbitrary.
            guard claimCounts[key] == 1 else {
                skips.append(Skip(track: candidate.track, reason: .collidesWithAnotherRename))
                continue
            }
            renames.append(
                Rename(
                    track: candidate.track,
                    destinationURL: candidate.destination,
                    oldStoredPath: candidate.track.seratoStoredPath,
                    newStoredPath: SeratoLibraryLocator.seratoStoredPath(
                        for: candidate.destination, rootDirectory: rootDirectory)
                ))
        }

        return Preview(
            databaseFileURL: databaseFileURL,
            rootDirectory: rootDirectory,
            renames: renames,
            skips: skips
        )
    }

    // MARK: - Apply

    /// Moves the files, then updates `database V2`, every crate and Serato's
    /// location databases — each in a single pass.
    @discardableResult
    public static func apply(
        _ preview: Preview,
        fileManager: FileManager = .default
    ) throws -> Result {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RenameError.seratoIsRunning
        }
        guard !preview.renames.isEmpty else {
            return Result(renamedCount: 0, skips: preview.skips, failures: [])
        }

        let databaseFileURL = preview.databaseFileURL
        let libraryDirectory = databaseFileURL.deletingLastPathComponent()

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        let originalDatabase = try Data(contentsOf: databaseFileURL)

        var moved: [Rename] = []
        func rollbackMoves() throws {
            for rename in moved.reversed() where fileManager.fileExists(atPath: rename.destinationURL.path) {
                do {
                    try fileManager.moveItem(at: rename.destinationURL, to: rename.sourceURL)
                } catch {
                    throw RenameError.rollbackFailed(rename.sourceURL, rename.destinationURL)
                }
            }
        }

        for rename in preview.renames {
            // The library can drift between preview and apply; a source that
            // vanished is skipped rather than aborting the whole batch.
            guard fileManager.fileExists(atPath: rename.sourceURL.path) else { continue }
            do {
                try fileManager.moveItem(at: rename.sourceURL, to: rename.destinationURL)
                moved.append(rename)
            } catch {
                try rollbackMoves()
                throw RenameError.fileMoveFailed(rename.sourceURL, rename.destinationURL, underlying: error)
            }
        }

        guard !moved.isEmpty else {
            return Result(renamedCount: 0, skips: preview.skips, failures: [])
        }

        let pathMap = Dictionary(
            moved.map { ($0.oldStoredPath, $0.newStoredPath) }, uniquingKeysWith: { first, _ in first })

        var rewrittenLocationDatabases: [URL] = []
        do {
            let rewritten = SeratoDatabaseWriter.rewritingPaths(pathMap, in: originalDatabase)

            // Crates first, and smart crates included: a `.scrate` keeps a
            // materialized member list, and a stale path there makes Serato
            // re-import the old name as a separate, missing track.
            try rewriteCrates(pathMap, libraryDirectory: libraryDirectory)

            for locationDatabaseURL in SeratoLocationDatabase.activeDatabases(
                forLibraryDirectory: libraryDirectory) {
                let summary = try SeratoLocationDatabase.rewritePaths(
                    pathMap, rootDirectory: preview.rootDirectory, in: locationDatabaseURL)
                if summary.updatedCount > 0 {
                    rewrittenLocationDatabases.append(locationDatabaseURL)
                }
            }

            try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)
        } catch {
            let inverse = Dictionary(
                pathMap.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            for locationDatabaseURL in rewrittenLocationDatabases {
                _ = try? SeratoLocationDatabase.rewritePaths(
                    inverse, rootDirectory: preview.rootDirectory, in: locationDatabaseURL)
            }
            try? rewriteCrates(inverse, libraryDirectory: libraryDirectory)
            try? AtomicFileWriter.write(originalDatabase, to: databaseFileURL)
            try rollbackMoves()
            throw error
        }

        return Result(renamedCount: moved.count, skips: preview.skips, failures: [])
    }

    /// One surgical pass per crate file, plain and smart alike.
    private static func rewriteCrates(_ pathMap: [String: String], libraryDirectory: URL) throws {
        let entries = SeratoLibraryLocator.subcrateFiles(in: libraryDirectory)
            + SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory)

        for entry in entries {
            let crateData = try Data(contentsOf: entry.url)
            let rewritten = SeratoCrateWriter.rewritingTrackPaths(pathMap, in: crateData)
            guard rewritten.rewrittenCount > 0 else { continue }

            try SeratoBackupBeforeWrite.snapshot(of: entry.url)
            try AtomicFileWriter.write(rewritten.data, to: entry.url)
        }
    }
}
