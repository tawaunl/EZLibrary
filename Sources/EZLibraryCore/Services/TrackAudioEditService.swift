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

/// Trims a library track and keeps Serato's library consistent with the result.
///
/// The cut itself is `AudioTrimService`'s job; what this adds is everything
/// Serato needs to agree with the new state of the disk:
///
/// - **Save in place** keeps the same path, so `database V2` and every crate
///   already point at the right file. Serato's cue points and beatgrid are
///   cleared by the trim (they're anchored to the old timeline), and Serato
///   re-analyzes the track the next time it loads it.
/// - **Save as a new file** registers the new path in `database V2` and adds it
///   to every plain crate the original belongs to, so the edit shows up
///   alongside the original instead of only existing on disk.
public enum TrackAudioEditService {
    public struct EditResult: Sendable {
        public let outputURL: URL
        public let replacedOriginal: Bool
        public let originalBackupURL: URL?
        /// Nil for in-place edits, whose path is unchanged.
        public let newStoredPath: String?
        public let addedToDatabase: Bool
        /// Names of the crates the new file was added to.
        public let cratesUpdated: [String]
        public let trimmedDuration: TimeInterval

        public init(
            outputURL: URL,
            replacedOriginal: Bool,
            originalBackupURL: URL?,
            newStoredPath: String?,
            addedToDatabase: Bool,
            cratesUpdated: [String],
            trimmedDuration: TimeInterval
        ) {
            self.outputURL = outputURL
            self.replacedOriginal = replacedOriginal
            self.originalBackupURL = originalBackupURL
            self.newStoredPath = newStoredPath
            self.addedToDatabase = addedToDatabase
            self.cratesUpdated = cratesUpdated
            self.trimmedDuration = trimmedDuration
        }
    }

    public enum EditError: Error, LocalizedError {
        case seratoIsRunning
        case databaseMissing(URL)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running, so the trimmed track can't be saved."
            case let .databaseMissing(url):
                return "Couldn't find Serato's library database at \(url.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its library from memory on quit, "
                    + "which would undo the change."
            case .databaseMissing:
                return "Check the library directory at the top of the Tracks view points at your _Serato_ folder."
            }
        }
    }

    /// What a trim of this track will discard, for the confirmation the user
    /// sees before saving. Cheap — reads only the file's leading ID3 tag.
    public static func analysisSummary(for track: Track) -> SeratoAnalysisSummary {
        SeratoAnalysisTagReader.summary(forFileAt: track.fileURL)
    }

    /// Trims the track and overwrites it, keeping a backup of the original.
    ///
    /// Blocking — call it off the main actor.
    @discardableResult
    public static func saveInPlace(
        track: Track,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        fileManager: FileManager = .default
    ) throws -> EditResult {
        // Serato caches loaded tracks and rewrites its library on quit; letting
        // it hold a file we're about to replace under it invites a stale or
        // half-analyzed entry.
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }

        let result = try AudioTrimService.trim(
            source: track.fileURL,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            to: .inPlace,
            fileManager: fileManager
        )

        return EditResult(
            outputURL: result.outputURL,
            replacedOriginal: true,
            originalBackupURL: result.originalBackupURL,
            newStoredPath: nil,
            addedToDatabase: false,
            cratesUpdated: [],
            trimmedDuration: result.trimmedDuration
        )
    }

    /// Trims the track into `destinationURL`, leaving the original alone, then
    /// registers the new file in `database V2` and in every plain crate that
    /// holds the original.
    ///
    /// Blocking — call it off the main actor.
    @discardableResult
    public static func saveAsNewFile(
        track: Track,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        destinationURL: URL,
        libraryDirectory: URL,
        addToCratesContainingOriginal: Bool = true,
        fileManager: FileManager = .default
    ) throws -> EditResult {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }

        let databaseFileURL = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw EditError.databaseMissing(databaseFileURL)
        }

        let result = try AudioTrimService.trim(
            source: track.fileURL,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            to: .newFile(destinationURL),
            fileManager: fileManager
        )

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        let newStoredPath = SeratoLibraryLocator.seratoStoredPath(
            for: destinationURL.standardizedFileURL, rootDirectory: rootDirectory)

        // From here on the audio file exists, so a library-write failure is
        // reported without deleting the user's freshly trimmed audio — they
        // keep the file and can re-add it.
        let originalData = try Data(contentsOf: databaseFileURL)
        let inserted = SeratoDatabaseWriter.ensuringTrackExists(
            forStoredPath: newStoredPath,
            metadata: metadataCarriedOver(from: track),
            in: originalData
        )

        if inserted.didInsert {
            try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
            try AtomicFileWriter.write(inserted.data, to: databaseFileURL)
        }

        var cratesUpdated: [String] = []
        if addToCratesContainingOriginal {
            cratesUpdated = try addToCrates(
                containing: track.seratoStoredPath,
                newStoredPath: newStoredPath,
                libraryDirectory: libraryDirectory
            )
        }

        return EditResult(
            outputURL: result.outputURL,
            replacedOriginal: false,
            originalBackupURL: nil,
            newStoredPath: newStoredPath,
            addedToDatabase: inserted.didInsert,
            cratesUpdated: cratesUpdated,
            trimmedDuration: result.trimmedDuration
        )
    }

    // MARK: - Crates

    /// Inserts `newStoredPath` directly after `originalStoredPath` in every
    /// plain crate that holds the original, so the edit files next to the
    /// track it came from rather than at the bottom of the crate.
    ///
    /// Smart crates are deliberately skipped: their member list is derived from
    /// rules and Serato regenerates it, so an entry written here would either
    /// be discarded or duplicate a match Serato makes on its own.
    static func addToCrates(
        containing originalStoredPath: String,
        newStoredPath: String,
        libraryDirectory: URL
    ) throws -> [String] {
        var updated: [String] = []

        for entry in SeratoLibraryLocator.subcrateFiles(in: libraryDirectory) {
            let crateData = try Data(contentsOf: entry.url)
            let paths = SeratoCrateParser.trackPaths(from: crateData)

            guard paths.contains(originalStoredPath), !paths.contains(newStoredPath) else { continue }

            var merged: [String] = []
            merged.reserveCapacity(paths.count + 1)
            for path in paths {
                merged.append(path)
                if path == originalStoredPath {
                    merged.append(newStoredPath)
                }
            }

            try SeratoBackupBeforeWrite.snapshot(of: entry.url)
            try AtomicFileWriter.write(SeratoCrateWriter.makeCrateData(trackPaths: merged), to: entry.url)
            updated.append(crateName(for: entry))
        }

        return updated
    }

    private static func crateName(for entry: SeratoLibraryLocator.CrateFileEntry) -> String {
        let baseName = entry.url.deletingPathExtension().lastPathComponent
        return Crate.pathComponents(forCrateFileNamed: baseName).joined(separator: " / ")
    }

    /// The tags the new record starts life with. Copied from the original so
    /// the edit is recognisable in Serato's browser before it gets analyzed.
    private static func metadataCarriedOver(from track: Track) -> SeratoTrackMetadataUpdate {
        SeratoTrackMetadataUpdate(
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            comment: track.comment,
            key: track.key ?? "",
            // BPM survives a trim (the tempo is unchanged) but the beatgrid
            // that anchors it does not; Serato rebuilds that on re-analysis.
            bpm: track.bpm,
            year: track.year
        )
    }
}
