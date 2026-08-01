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
import SQLite3

/// Rewrites track paths in `_Serato_/Library/location.sqlite`, the SQLite
/// library Serato DJ Pro 3.x/4.x actually reads from.
///
/// `database V2` and the `.crate` files are a legacy interop layer that
/// modern Serato only *imports* from (see the `dbv2_status` and
/// `last_seen_dbv2_library` tables), keyed on the file's path. Rewriting
/// only `database V2` therefore leaves `location.sqlite` pointing at the old
/// path: Serato shows the track as missing, and re-importing the changed
/// `database V2` adds the renamed file as a brand-new asset — orphaning the
/// original row along with its cue points, beat grid, play count and crate
/// membership, all of which hang off `asset.id`.
///
/// Updating `asset.portable_id` in place keeps that `asset.id` stable, so
/// everything attached to the track survives a rename.
public enum SeratoLocationDatabase {
    public enum LocationError: Error, Equatable {
        /// `location.sqlite` exists but `sqlite3_open_v2` refused it.
        case cannotOpen(String)
        /// The file opened but doesn't look like a Serato location database.
        /// Refusing to touch it is safer than guessing at an unknown schema.
        case unsupportedSchema
        case sqliteError(String)
    }

    /// Outcome of a rewrite pass, so callers can report partial success
    /// instead of treating an unmatched track as a hard failure.
    public struct RewriteSummary: Sendable, Equatable {
        /// Number of `asset` rows whose path was updated.
        public let updatedCount: Int
        /// Old paths that had no matching `asset` row. Normal for tracks
        /// Serato has never seen, and for libraries with no `location.sqlite`.
        public let unmatchedPaths: [String]
        /// Old paths skipped because a *different* `asset` row already claims
        /// the destination path — updating would violate the unique index.
        public let conflictingPaths: [String]

        public static let empty = RewriteSummary(updatedCount: 0, unmatchedPaths: [], conflictingPaths: [])
    }

    /// One row of the `asset` table, limited to the columns anything outside
    /// this file has a reason to look at.
    public struct AssetRecord: Sendable, Equatable {
        public let id: Int64
        public let portableID: String
        public let fileName: String
        /// `NULL` for assets Serato has never had a readable file for.
        public let fileSize: Int64?
    }

    /// A path change addressed by `asset.id` rather than by old path, for
    /// callers that have already worked out which row they mean.
    public struct AssetPathUpdate: Sendable, Equatable {
        public let id: Int64
        public let portableID: String
        public let fileName: String

        public init(id: Int64, portableID: String, fileName: String) {
            self.id = id
            self.portableID = portableID
            self.fileName = fileName
        }
    }

    /// `_Serato_/Library/location.sqlite` for a given `_Serato_` directory.
    public static func locationDatabaseFile(in libraryDirectory: URL) -> URL {
        libraryDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("location.sqlite")
    }

    /// Every asset Serato knows about. Empty when the library has no
    /// `location.sqlite`, matching `rewritePaths`' treatment of that case.
    public static func assets(in locationDatabaseURL: URL) throws -> [AssetRecord] {
        guard FileManager.default.fileExists(atPath: locationDatabaseURL.path) else {
            return []
        }

        let handle = try Connection(url: locationDatabaseURL)
        defer { handle.close() }

        guard handle.hasLocationSchema else {
            throw LocationError.unsupportedSchema
        }
        return try handle.allAssets()
    }

    /// Applies path updates addressed by `asset.id`. Same in-place semantics
    /// as `rewritePaths` — the row keeps its identity, so cues, beat grids,
    /// play counts and crate membership come along with it.
    @discardableResult
    public static func rewriteAssetPaths(
        _ updates: [AssetPathUpdate],
        in locationDatabaseURL: URL
    ) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        guard FileManager.default.fileExists(atPath: locationDatabaseURL.path) else {
            return 0
        }

        try SeratoBackupBeforeWrite.snapshot(of: locationDatabaseURL)

        let handle = try Connection(url: locationDatabaseURL)
        defer { handle.close() }

        guard handle.hasLocationSchema else {
            throw LocationError.unsupportedSchema
        }

        let currentRevision = handle.currentRevision
        var updatedCount = 0

        try handle.transaction {
            for update in updates {
                // Still checked per row: the caller's plan was built against a
                // snapshot, and a destination taken in the meantime would
                // otherwise trip the unique index and roll back the batch.
                if try handle.assetID(forPortableID: update.portableID).map({ $0 != update.id }) == true {
                    continue
                }
                try handle.updateAssetPath(
                    id: update.id,
                    portableID: update.portableID,
                    fileName: update.fileName,
                    revision: currentRevision
                )
                try handle.touchSpaces(forAssetID: update.id, revision: currentRevision)
                updatedCount += 1
            }
        }

        return updatedCount
    }

    /// Rewrites `asset.portable_id`/`asset.file_name` for every entry in
    /// `rewrites`, a map of old to new *Serato stored path* (the `pfil`
    /// convention, relative to `rootDirectory`).
    ///
    /// A missing `location.sqlite` is not an error — Serato 2.x libraries
    /// don't have one, and neither does a library that has never been opened
    /// by a version that uses it. That case returns an empty summary so the
    /// caller's `database V2` rewrite still stands on its own.
    @discardableResult
    public static func rewritePaths(
        _ rewrites: [String: String],
        rootDirectory: URL,
        in locationDatabaseURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> RewriteSummary {
        guard !rewrites.isEmpty else { return .empty }
        guard FileManager.default.fileExists(atPath: locationDatabaseURL.path) else {
            return .empty
        }

        try SeratoBackupBeforeWrite.snapshot(of: locationDatabaseURL)

        let handle = try Connection(url: locationDatabaseURL)
        defer { handle.close() }

        guard handle.hasLocationSchema else {
            throw LocationError.unsupportedSchema
        }

        // Serato's own triggers stamp rows with the current global revision
        // rather than inventing a new one, so a rewrite does the same: the
        // row is marked changed as of "now" without disturbing the counter
        // Serato uses to decide what still needs syncing.
        let currentRevision = handle.currentRevision

        // Resolved up front: `resolve` stats the filesystem for libraries on
        // an external volume, and a few thousand of those shouldn't happen
        // while holding the database's write lock.
        let resolved = rewrites
            .sorted { $0.key < $1.key }
            .filter { $0.key != $0.value }
            .map { oldStoredPath, newStoredPath in
                (
                    oldStoredPath: oldStoredPath,
                    oldURL: SeratoLibraryLocator.resolve(seratoStoredPath: oldStoredPath, rootDirectory: rootDirectory),
                    newURL: SeratoLibraryLocator.resolve(seratoStoredPath: newStoredPath, rootDirectory: rootDirectory)
                )
            }

        var updatedCount = 0
        var unmatchedPaths: [String] = []
        var conflictingPaths: [String] = []

        try handle.transaction {
            for (oldStoredPath, oldURL, newURL) in resolved {
                guard let match = try findAsset(
                    for: oldURL,
                    rootDirectory: rootDirectory,
                    homeDirectory: homeDirectory,
                    handle: handle
                ) else {
                    unmatchedPaths.append(oldStoredPath)
                    continue
                }

                // Reuse the base the old row was written against so the new
                // portable ID stays in whatever convention this library uses,
                // instead of imposing the one we happened to guess first.
                let newPortableID = portableID(for: newURL, relativeTo: match.base)
                if try handle.assetID(forPortableID: newPortableID).map({ $0 != match.id }) == true {
                    conflictingPaths.append(oldStoredPath)
                    continue
                }

                try handle.updateAssetPath(
                    id: match.id,
                    portableID: newPortableID,
                    fileName: newURL.lastPathComponent,
                    revision: currentRevision
                )
                try handle.touchSpaces(forAssetID: match.id, revision: currentRevision)
                updatedCount += 1
            }
        }

        return RewriteSummary(
            updatedCount: updatedCount,
            unmatchedPaths: unmatchedPaths,
            conflictingPaths: conflictingPaths
        )
    }

    // MARK: - Portable IDs

    /// `portable_id` is a path relative to some base directory, and which
    /// base depends on where the library lives — confirmed as `$HOME` for a
    /// boot-volume library (`Music/All Music/track.mp3` for
    /// `~/Music/All Music/track.mp3`, where `database V2` stores
    /// `Users/me/Music/All Music/track.mp3`).
    ///
    /// Rather than hard-coding that rule and getting it wrong for external
    /// drives, the base is discovered per track by trying each candidate
    /// against the unique index and keeping the one that resolves to a real
    /// row. Whatever matched is then reused to build the new ID.
    private static func candidateBases(rootDirectory: URL, homeDirectory: URL) -> [URL] {
        var bases = [homeDirectory, rootDirectory, URL(fileURLWithPath: "/", isDirectory: true)]
        var seen = Set<String>()
        bases = bases.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return bases
    }

    private struct AssetMatch {
        let id: Int64
        let base: URL
    }

    private static func findAsset(
        for fileURL: URL,
        rootDirectory: URL,
        homeDirectory: URL,
        handle: Connection
    ) throws -> AssetMatch? {
        for base in candidateBases(rootDirectory: rootDirectory, homeDirectory: homeDirectory) {
            let candidate = portableID(for: fileURL, relativeTo: base)
            guard !candidate.isEmpty else { continue }
            if let id = try handle.assetID(forPortableID: candidate) {
                return AssetMatch(id: id, base: base)
            }
        }
        return nil
    }

    private static func portableID(for fileURL: URL, relativeTo base: URL) -> String {
        var basePath = base.standardizedFileURL.path
        if !basePath.hasSuffix("/") { basePath += "/" }

        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return "" }
        return String(filePath.dropFirst(basePath.count))
    }

    // MARK: - Minimal SQLite wrapper

    /// Just enough of a SQLite binding for the handful of statements above.
    /// Deliberately not a general-purpose layer: this is the only place in
    /// the codebase that talks to SQLite, and a narrow surface keeps the
    /// pointer lifetimes obvious.
    private final class Connection {
        private var db: OpaquePointer?

        init(url: URL) throws {
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
            guard result == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
                sqlite3_close_v2(handle)
                throw LocationError.cannotOpen(message)
            }
            db = handle
            // Serato may still hold the file briefly after quitting; wait
            // rather than failing the rewrite outright.
            sqlite3_busy_timeout(handle, 3000)
        }

        func close() {
            sqlite3_close_v2(db)
            db = nil
        }

        var hasLocationSchema: Bool {
            let tables = ["asset", "serato", "space", "space_asset"]
            for table in tables {
                let exists = (try? scalarInt(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    text: table
                )) ?? 0
                guard exists > 0 else { return false }
            }
            // These are the columns everything here keys on; a schema that
            // renamed them is one we don't understand.
            for column in ["portable_id", "file_name", "file_size", "revision"] {
                let exists = (try? scalarInt(
                    "SELECT COUNT(*) FROM pragma_table_info('asset') WHERE name = ?1",
                    text: column
                )) ?? 0
                guard exists > 0 else { return false }
            }
            return true
        }

        func allAssets() throws -> [AssetRecord] {
            let statement = try prepare("SELECT id, portable_id, file_name, file_size FROM asset")
            defer { sqlite3_finalize(statement) }

            var records: [AssetRecord] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let id = sqlite3_column_int64(statement, 0)
                    let portableID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                    let fileName = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                    let fileSize = sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_int64(statement, 3)
                    records.append(
                        AssetRecord(id: id, portableID: portableID, fileName: fileName, fileSize: fileSize)
                    )
                case SQLITE_DONE:
                    return records
                default:
                    throw lastError()
                }
            }
        }

        var currentRevision: Int64 {
            (try? scalarInt("SELECT COALESCE(MAX(revision), 0) FROM serato")) ?? 0
        }

        func assetID(forPortableID portableID: String) throws -> Int64? {
            // `asset__unique_portable_id` is a NOCASE index, so the lookup
            // has to opt into that collation to both use the index and match
            // the same way Serato's uniqueness rule does.
            let statement = try prepare("SELECT id FROM asset WHERE portable_id = ?1 COLLATE NOCASE LIMIT 1")
            defer { sqlite3_finalize(statement) }
            try bind(text: portableID, to: statement, at: 1)

            switch sqlite3_step(statement) {
            case SQLITE_ROW: return sqlite3_column_int64(statement, 0)
            case SQLITE_DONE: return nil
            default: throw lastError()
            }
        }

        func updateAssetPath(id: Int64, portableID: String, fileName: String, revision: Int64) throws {
            let statement = try prepare("""
                UPDATE asset
                   SET portable_id = ?1,
                       file_name = ?2,
                       revision = MAX(revision, ?3)
                 WHERE id = ?4
                """)
            defer { sqlite3_finalize(statement) }
            try bind(text: portableID, to: statement, at: 1)
            try bind(text: fileName, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, revision)
            sqlite3_bind_int64(statement, 4, id)
            try step(statement)
        }

        /// Mirrors Serato's own `track_space_changes_when_asset_*` triggers,
        /// which only fire on insert/delete of `space_asset` — an in-place
        /// path edit has to bump the containing space itself.
        func touchSpaces(forAssetID assetID: Int64, revision: Int64) throws {
            let statement = try prepare("""
                UPDATE space
                   SET revision = ?1
                 WHERE id IN (SELECT space_id FROM space_asset WHERE asset_id = ?2)
                   AND revision < ?1
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, revision)
            sqlite3_bind_int64(statement, 2, assetID)
            try step(statement)
        }

        func transaction(_ body: () throws -> Void) throws {
            try execute("BEGIN IMMEDIATE")
            do {
                try body()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        // MARK: Primitives

        private func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError()
            }
            return statement
        }

        private func bind(text: String, to statement: OpaquePointer?, at index: Int32) throws {
            // SQLITE_TRANSIENT: sqlite must copy the bytes, because the
            // String's buffer doesn't outlive this call.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
                throw lastError()
            }
        }

        private func step(_ statement: OpaquePointer?) throws {
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw lastError()
            }
        }

        private func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw lastError()
            }
        }

        private func scalarInt(_ sql: String, text: String? = nil) throws -> Int64 {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let text {
                try bind(text: text, to: statement, at: 1)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }

        private func lastError() -> LocationError {
            .sqliteError(String(cString: sqlite3_errmsg(db)))
        }
    }
}
