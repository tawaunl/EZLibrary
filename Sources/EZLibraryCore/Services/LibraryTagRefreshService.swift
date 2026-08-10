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

/// Rewrites library entries from the tags stored in the audio files themselves.
///
/// Serato entries can drift from their files — an entry added from a filename
/// guess carries whatever that guess produced, and nothing later corrects it
/// because a folder sync only writes metadata for tracks it inserts. This walks
/// existing tracks, reads each file's real tags, and reports the differences so
/// they can be reviewed before anything is written.
public enum LibraryTagRefreshService {
    /// One field that disagrees between the library and the file.
    public struct FieldChange: Sendable, Equatable {
        public let field: String
        public let before: String
        public let after: String

        public init(field: String, before: String, after: String) {
            self.field = field
            self.before = before
            self.after = after
        }
    }

    public struct Change: Sendable {
        public let track: Track
        public let metadata: SeratoTrackMetadataUpdate
        public let fields: [FieldChange]

        public init(track: Track, metadata: SeratoTrackMetadataUpdate, fields: [FieldChange]) {
            self.track = track
            self.metadata = metadata
            self.fields = fields
        }
    }

    public struct Plan: Sendable {
        public let changes: [Change]
        /// Tracks whose file is gone, so their tags could not be read.
        public let missingFiles: [Track]
        /// Tracks whose file carries no usable tags to copy from.
        public let untaggedFiles: [Track]
        /// Tracks that already match their file.
        public let unchangedCount: Int

        public var isEmpty: Bool { changes.isEmpty }

        public init(
            changes: [Change],
            missingFiles: [Track],
            untaggedFiles: [Track],
            unchangedCount: Int
        ) {
            self.changes = changes
            self.missingFiles = missingFiles
            self.untaggedFiles = untaggedFiles
            self.unchangedCount = unchangedCount
        }
    }

    public enum RefreshError: LocalizedError {
        case databaseNotFound(URL)
        case seratoIsRunning

        public var errorDescription: String? {
            switch self {
            case let .databaseNotFound(url):
                return "Serato database V2 was not found at \(url.path)."
            case .seratoIsRunning:
                return "Serato is currently running. Quit Serato before updating tags so it doesn't overwrite the changes."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .databaseNotFound:
                return "Open Serato once to initialize the library, then retry."
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its library from memory on quit, which would revert these edits."
            }
        }
    }

    /// Builds the list of entries that disagree with their files.
    ///
    /// A field is only ever replaced when the file actually carries a value for
    /// it, so a file missing a tag never blanks out what the library already
    /// holds. With `onlyFillEmpty` the library wins wherever it has any value,
    /// which limits the pass to filling gaps.
    public static func plan(
        for tracks: [Track],
        onlyFillEmpty: Bool = false,
        maxConcurrentReads: Int = 8,
        fileManager: FileManager = .default
    ) async -> Plan {
        guard !tracks.isEmpty else {
            return Plan(changes: [], missingFiles: [], untaggedFiles: [], unchangedCount: 0)
        }

        enum Outcome: Sendable {
            case change(Change)
            case missing(Track)
            case untagged(Track)
            case unchanged
        }

        var outcomes: [Outcome] = []
        var iterator = tracks.makeIterator()

        await withTaskGroup(of: Outcome.self) { group in
            func addNext() {
                guard let track = iterator.next() else { return }
                // Checked out here so the task closure doesn't capture the
                // file manager and trip the sending-closure check.
                let exists = fileManager.fileExists(atPath: track.fileURL.path)
                group.addTask {
                    guard exists else { return .missing(track) }

                    let tags = await AudioFileTagReader.readTags(from: track.fileURL)
                    if tags.isEmpty { return .untagged(track) }

                    guard let change = change(for: track, tags: tags, onlyFillEmpty: onlyFillEmpty) else {
                        return .unchanged
                    }
                    return .change(change)
                }
            }

            for _ in 0..<min(maxConcurrentReads, tracks.count) { addNext() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                addNext()
            }
        }

        var changes: [Change] = []
        var missing: [Track] = []
        var untagged: [Track] = []
        var unchanged = 0

        for outcome in outcomes {
            switch outcome {
            case let .change(change): changes.append(change)
            case let .missing(track): missing.append(track)
            case let .untagged(track): untagged.append(track)
            case .unchanged: unchanged += 1
            }
        }

        changes.sort { $0.track.fileURL.path.localizedStandardCompare($1.track.fileURL.path) == .orderedAscending }

        return Plan(
            changes: changes,
            missingFiles: missing,
            untaggedFiles: untagged,
            unchangedCount: unchanged
        )
    }

    private static func change(
        for track: Track,
        tags: AudioFileTagReader.Tags,
        onlyFillEmpty: Bool
    ) -> Change? {
        var fields: [FieldChange] = []

        func resolve(_ field: String, current: String, incoming: String?) -> String {
            guard let incoming = incoming?.trimmingCharacters(in: .whitespacesAndNewlines), !incoming.isEmpty else {
                return current
            }
            if onlyFillEmpty, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return current
            }
            guard incoming != current else { return current }
            fields.append(FieldChange(field: field, before: current, after: incoming))
            return incoming
        }

        let title = resolve("Title", current: track.title, incoming: tags.title)
        let artist = resolve("Artist", current: track.artist, incoming: tags.artist)
        let album = resolve("Album", current: track.album, incoming: tags.album)
        let genre = resolve("Genre", current: track.genre, incoming: tags.genre)

        var year = track.year
        if let incoming = tags.year, incoming != track.year, !(onlyFillEmpty && track.year != nil) {
            fields.append(FieldChange(
                field: "Year",
                before: track.year.map(String.init) ?? "",
                after: String(incoming)
            ))
            year = incoming
        }

        guard !fields.isEmpty else { return nil }

        return Change(
            track: track,
            metadata: SeratoTrackMetadataUpdate(
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                comment: track.comment,
                key: track.key ?? "",
                bpm: track.bpm,
                year: year
            ),
            fields: fields
        )
    }

    /// Writes a plan to the database, snapshotting it first. Returns how many
    /// entries were rewritten.
    @discardableResult
    public static func apply(
        _ plan: Plan,
        databaseFileURL: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard !plan.changes.isEmpty else { return 0 }

        // Serato rewrites its library from memory when it quits, so any change
        // made while it is running is liable to be reverted. Every service that
        // mutates the library refuses for the same reason.
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RefreshError.seratoIsRunning
        }

        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw RefreshError.databaseNotFound(databaseFileURL)
        }

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        let data = try Data(contentsOf: databaseFileURL)

        // Keyed on the path each entry was actually read with, so an entry
        // written under either path convention is matched exactly.
        var metadataByStoredPath: [String: SeratoTrackMetadataUpdate] = [:]
        for change in plan.changes {
            metadataByStoredPath[change.track.seratoStoredPath] = change.metadata
        }

        let result = SeratoDatabaseWriter.rewritingMetadata(byStoredPath: metadataByStoredPath, in: data)
        guard result.rewrittenCount > 0 else { return 0 }

        try AtomicFileWriter.write(result.data, to: databaseFileURL)
        return result.rewrittenCount
    }
}
