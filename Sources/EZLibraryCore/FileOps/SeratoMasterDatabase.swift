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

/// Reads and repairs `master.sqlite`, Serato's aggregate library.
///
/// Separate from `SeratoLocationDatabase` because the schema genuinely
/// differs: `master.asset` carries a `location_id` and no `revision`, and
/// `master.serato`/`master.space` have no revision columns at all. Sharing one
/// type would mean a schema probe that accepts both and silently does the
/// wrong thing against whichever it got.
///
/// **A `location` whose id has no `connection` row is disconnected**: Serato
/// keeps showing its assets but never syncs them from their original
/// database again, so a stale row there is a permanent "cannot be located"
/// entry until something edits `master.sqlite` itself.
public enum SeratoMasterDatabase {
    public enum MasterError: Error, Equatable {
        case cannotOpen(String)
        /// Opened, but doesn't look like Serato's aggregate database.
        case unsupportedSchema
        /// A column guarded by Serato's `after_asset_update` trigger was
        /// going to be written. See `rewritePortableIDs`.
        case requiresSeratoRuntime(String)
        case sqliteError(String)
    }

    public struct AssetRecord: Sendable, Equatable {
        public let id: Int64
        public let locationID: Int64
        public let portableID: String
        public let fileName: String
    }

    /// Location ids that Serato still aggregates but no longer syncs.
    public static func disconnectedLocationIDs(in masterDatabaseURL: URL) throws -> [Int64] {
        let handle = try Connection(url: masterDatabaseURL)
        defer { handle.close() }
        guard handle.hasMasterSchema else { throw MasterError.unsupportedSchema }
        return try handle.int64Column(
            "SELECT l.id FROM location l LEFT JOIN connection c ON c.location_id = l.id WHERE c.location_id IS NULL"
        )
    }

    public static func assets(in masterDatabaseURL: URL, locationID: Int64) throws -> [AssetRecord] {
        let handle = try Connection(url: masterDatabaseURL)
        defer { handle.close() }
        guard handle.hasMasterSchema else { throw MasterError.unsupportedSchema }
        return try handle.assets(locationID: locationID)
    }

    /// Re-points assets by `asset.id`, writing **only** `portable_id`.
    ///
    /// `master.sqlite`'s `after_asset_update` trigger fires on `file_name`
    /// (among other display columns) and calls `serato_str_norm()` — a
    /// function Serato registers on its own connection at runtime. Any
    /// statement touching those columns from outside the app fails with
    /// "no such function", so this deliberately never writes them: callers
    /// must only submit updates whose filename is unchanged, which
    /// `verifyFileNamesUnchanged` enforces.
    @discardableResult
    public static func rewritePortableIDs(
        _ updates: [(id: Int64, portableID: String)],
        in masterDatabaseURL: URL
    ) throws -> Int {
        guard !updates.isEmpty else { return 0 }

        try SeratoBackupBeforeWrite.snapshot(of: masterDatabaseURL)

        let handle = try Connection(url: masterDatabaseURL)
        defer { handle.close() }
        guard handle.hasMasterSchema else { throw MasterError.unsupportedSchema }

        try handle.verifyFileNamesUnchanged(updates)

        var updated = 0
        try handle.transaction {
            for update in updates {
                try handle.updatePortableID(id: update.id, portableID: update.portableID)
                updated += 1
            }
        }
        return updated
    }

    // MARK: - SQLite

    private final class Connection {
        private var db: OpaquePointer?

        init(url: URL) throws {
            var handle: OpaquePointer?
            // Read-write even for reads: master.sqlite is in WAL mode and a
            // read-only connection can't create the -shm file WAL needs,
            // which makes every statement fail with SQLITE_CANTOPEN.
            let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
            guard result == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
                sqlite3_close_v2(handle)
                throw MasterError.cannotOpen(message)
            }
            db = handle
            sqlite3_busy_timeout(handle, 3000)
        }

        func close() {
            sqlite3_close_v2(db)
            db = nil
        }

        var hasMasterSchema: Bool {
            for table in ["asset", "location", "connection"] {
                let exists = (try? scalarInt(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1", text: table
                )) ?? 0
                guard exists > 0 else { return false }
            }
            // `location_id` is what distinguishes the aggregate from a plain
            // location database, which has no such column.
            let hasLocationID = (try? scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('asset') WHERE name = 'location_id'"
            )) ?? 0
            return hasLocationID > 0
        }

        func assets(locationID: Int64) throws -> [AssetRecord] {
            let statement = try prepare(
                "SELECT id, location_id, portable_id, COALESCE(file_name, '') FROM asset WHERE location_id = ?1")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, locationID)

            var records: [AssetRecord] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    records.append(
                        AssetRecord(
                            id: sqlite3_column_int64(statement, 0),
                            locationID: sqlite3_column_int64(statement, 1),
                            portableID: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                            fileName: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
                        ))
                case SQLITE_DONE:
                    return records
                default:
                    throw lastError()
                }
            }
        }

        /// Refuses the whole batch if any update would change a row's
        /// filename, since writing `file_name` needs Serato's runtime.
        func verifyFileNamesUnchanged(_ updates: [(id: Int64, portableID: String)]) throws {
            for update in updates {
                let statement = try prepare("SELECT COALESCE(file_name, '') FROM asset WHERE id = ?1")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, update.id)
                guard sqlite3_step(statement) == SQLITE_ROW else { continue }
                let current = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let proposed = (update.portableID as NSString).lastPathComponent
                if current != proposed {
                    throw MasterError.requiresSeratoRuntime(
                        "asset \(update.id): '\(current)' -> '\(proposed)'")
                }
            }
        }

        func updatePortableID(id: Int64, portableID: String) throws {
            let statement = try prepare("UPDATE asset SET portable_id = ?1 WHERE id = ?2")
            defer { sqlite3_finalize(statement) }
            try bind(text: portableID, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, id)
            try step(statement)
        }

        func int64Column(_ sql: String) throws -> [Int64] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var values: [Int64] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: values.append(sqlite3_column_int64(statement, 0))
                case SQLITE_DONE: return values
                default: throw lastError()
                }
            }
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

        private func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
            return statement
        }

        private func bind(text: String, to statement: OpaquePointer?, at index: Int32) throws {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw lastError() }
        }

        private func step(_ statement: OpaquePointer?) throws {
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError() }
        }

        private func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
        }

        private func scalarInt(_ sql: String, text: String? = nil) throws -> Int64 {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let text { try bind(text: text, to: statement, at: 1) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }

        private func lastError() -> MasterError {
            .sqliteError(String(cString: sqlite3_errmsg(db)))
        }
    }
}
