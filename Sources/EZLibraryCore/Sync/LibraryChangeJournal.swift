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

/// One dated thing EZLibrary did to the library.
public struct LibraryChangeEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let change: LibraryChange

    public init(id: UUID = UUID(), recordedAt: Date = Date(), change: LibraryChange) {
        self.id = id
        self.recordedAt = recordedAt.truncatedToWholeSeconds
        self.change = change
    }
}

/// The kinds of change the journal records.
///
/// Only changes EZLibrary itself performs appear here. Serato writes to the
/// same files and leaves nothing behind, so an unexplained difference between
/// a snapshot and reality means an external edit — which reconciliation has
/// to present differently, because there is no second value to offer.
public enum LibraryChange: Codable, Sendable, Hashable {
    /// A track's file moved, e.g. by Library Consolidation. Paths are
    /// `seratoStoredPath` values, not absolute URLs.
    case trackMoved(from: String, to: String)

    /// A single metadata field was rewritten. `from` and `to` are `nil` when
    /// the field was unset on that side.
    case trackFieldEdited(path: String, field: TrackField, from: String?, to: String?)
}

/// An append-only, dated log of the changes EZLibrary has applied.
///
/// This exists so a device working from an older snapshot can be reconciled
/// exactly rather than by inference: when Library Consolidation moves 2,000
/// files, that is not weather, it is something this app did and can account
/// for precisely.
public struct LibraryChangeJournal: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var entries: [LibraryChangeEntry]

    public init(schemaVersion: Int = LibraryChangeJournal.currentSchemaVersion, entries: [LibraryChangeEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    // MARK: - Recording

    public mutating func record(_ change: LibraryChange, at date: Date = Date()) {
        entries.append(LibraryChangeEntry(recordedAt: date, change: change))
    }

    /// Records a batch of moves under one timestamp — the shape
    /// `LibraryConsolidationService` produces, where a single operation
    /// relocates many files at once.
    public mutating func recordMoves(_ pathMap: [String: String], at date: Date = Date()) {
        // Sorted so a journal written twice from the same map is identical.
        for (from, to) in pathMap.sorted(by: { $0.key < $1.key }) where from != to {
            record(.trackMoved(from: from, to: to), at: date)
        }
    }

    // MARK: - Queries

    /// Follows the move chain forward and returns where `path` lives now.
    ///
    /// Handles a file moved more than once (consolidated, then renamed) by
    /// walking entries in recorded order, which also means a file moved away
    /// and back resolves correctly to its original path.
    public func currentPath(for path: String, since: Date? = nil) -> String {
        var current = path
        for entry in entries {
            if let since, entry.recordedAt <= since { continue }
            guard case let .trackMoved(from, to) = entry.change, from == current else { continue }
            current = to
        }
        return current
    }

    /// Every field edit recorded after `date` that applies to the same track
    /// as `path`, accounting for moves on either side.
    ///
    /// Linear in journal size per lookup, which is fine at the scale a journal
    /// reaches; revisit if one ever grows past tens of thousands of entries.
    public func fieldEdits(for path: String, field: TrackField, since date: Date) -> [LibraryChangeEntry] {
        let target = currentPath(for: path)
        return entries.filter { entry in
            guard entry.recordedAt > date else { return false }
            guard case let .trackFieldEdited(editedPath, editedField, _, _) = entry.change else { return false }
            guard editedField == field else { return false }
            return currentPath(for: editedPath) == target
        }
    }

    /// The most recent value this journal believes `field` was set to, or
    /// `nil` when it has no opinion.
    public func latestRecordedValue(for path: String, field: TrackField, since date: Date) -> String?? {
        guard let last = fieldEdits(for: path, field: field, since: date).last,
              case let .trackFieldEdited(_, _, _, to) = last.change else {
            return nil
        }
        return .some(to)
    }

    /// Drops entries older than `date`.
    ///
    /// Retention is not a detail: pruning past a snapshot's timestamp makes
    /// that snapshot unreconcilable, because the chain back to its base is
    /// gone. Never prune past the oldest snapshot you would still accept work
    /// from — see `LibraryChangeJournal.defaultRetention`.
    public func pruned(before date: Date) -> LibraryChangeJournal {
        LibraryChangeJournal(schemaVersion: schemaVersion, entries: entries.filter { $0.recordedAt >= date })
    }

    /// How far back the journal is kept, and therefore how old a snapshot may
    /// be and still be reconciled exactly.
    public static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60

    /// Whether work based on a snapshot taken at `date` can still be
    /// reconciled against this journal.
    public func canReconcile(snapshotTakenAt date: Date, now: Date = Date()) -> Bool {
        guard let earliest = entries.map(\.recordedAt).min() else {
            // An empty journal has lost nothing, so it explains everything.
            return now.timeIntervalSince(date) <= Self.defaultRetention
        }
        return date >= earliest || now.timeIntervalSince(date) <= Self.defaultRetention
    }

    // MARK: - Persistence

    public static let defaultFileName = "change-journal.json"

    /// Redirects the journal away from the real Application Support folder.
    ///
    /// `nonisolated(unsafe)`: a test-only seam, matching
    /// `SeratoLocationDatabase.applicationSupportDirectoryOverride`. Without
    /// it, any test that consolidates a fixture library would append to the
    /// developer's own journal.
    public nonisolated(unsafe) static var applicationSupportDirectoryOverride: URL?

    /// `~/Library/Application Support/EZLibrary/change-journal.json`
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = applicationSupportDirectoryOverride
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("EZLibrary", isDirectory: true)
            .appendingPathComponent(defaultFileName)
    }

    /// Loads a journal, returning an empty one when the file is absent or
    /// unreadable.
    ///
    /// A missing journal is not an error — it degrades reconciliation from
    /// exact to best-effort, which the resolver already handles.
    public static func load(from url: URL? = defaultURL()) -> LibraryChangeJournal {
        guard let url, let data = try? Data(contentsOf: url) else { return LibraryChangeJournal() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(LibraryChangeJournal.self, from: data),
              journal.schemaVersion <= currentSchemaVersion else {
            return LibraryChangeJournal()
        }
        return journal
    }

    /// Writes the journal atomically, creating the container directory when
    /// it does not exist yet.
    public func save(to url: URL? = defaultURL(), fileManager: FileManager = .default) throws {
        guard let url else { throw JournalError.noApplicationSupportDirectory }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(self), to: url)
    }

    public enum JournalError: Error, LocalizedError {
        case noApplicationSupportDirectory

        public var errorDescription: String? {
            switch self {
            case .noApplicationSupportDirectory:
                return "Couldn't find the Application Support folder to store EZLibrary's change history."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .noApplicationSupportDirectory:
                return "Check that your home folder is available, then try again."
            }
        }
    }
}
