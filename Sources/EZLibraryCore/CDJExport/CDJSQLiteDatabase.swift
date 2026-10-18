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
import SQLCipher

/// A value bound to, or read from, a SQL statement.
enum CDJSQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)

    var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    static func int(_ value: Int) -> CDJSQLValue { .int(Int64(value)) }
    static func int(_ value: UInt32) -> CDJSQLValue { .int(Int64(value)) }
}

struct CDJSQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The small slice of SQLCipher the OneLibrary database needs: open under a
/// key, run statements with bound values, read rows back.
final class CDJSQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens (creating if needed) the database at `url` under `passphrase`.
    ///
    /// The cipher settings come before the key and the key before everything
    /// else, or the file is read under the wrong parameters (or created as plain
    /// SQLite, which no player can read).
    init(url: URL, passphrase: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw CDJSQLiteError(message: "Couldn't open \(url.lastPathComponent): \(message)")
        }
        try execute("PRAGMA cipher = 'sqlcipher'")
        try execute("PRAGMA legacy = 4")
        // Built here rather than through `execute`, whose errors quote the statement.
        let quoted = passphrase.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(handle, "PRAGMA key = '\(quoted)'", nil, nil, nil) == SQLITE_OK else {
            throw CDJSQLiteError(message: "Couldn't apply the encryption key to \(url.lastPathComponent).")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CDJSQLiteError(message: "\(lastError) (\(sql.prefix(60)))")
        }
    }

    /// Runs one statement with `values` bound to its `?` placeholders.
    func run(_ sql: String, _ values: [CDJSQLValue] = []) throws {
        _ = try rows(sql, values, columns: 0)
    }

    /// Runs a query and returns `columns` values per row.
    func rows(_ sql: String, _ values: [CDJSQLValue] = [], columns: Int) throws -> [[CDJSQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CDJSQLiteError(message: "\(lastError) (\(sql.prefix(60)))")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            }
        }
        var result: [[CDJSQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CDJSQLiteError(message: lastError) }
            result.append((0..<columns).map { column in
                switch sqlite3_column_type(statement, Int32(column)) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, Int32(column)))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, Int32(column))))
                default: return .null
                }
            })
        }
        return result
    }
}
