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

/// Reads and writes `LibrarySnapshot` files.
///
/// The portable half lives here — encoding, decoding, naming, and reading.
/// `EZLibraryCore` extends this with the two operations that need a real
/// Serato library on disk: building a snapshot from parsed tracks, and
/// writing one through the app's atomic-write machinery.
///
/// A snapshot is disposable: a newer one supersedes it, and losing one costs
/// an export, never data. That is what keeps this side of the system simple —
/// there is no long-lived remote database to keep consistent.
public enum LibrarySnapshotBuilder {
    /// Snapshots travel between devices and OS versions, so dates are ISO 8601
    /// rather than the default seconds-since-reference-date.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ snapshot: LibrarySnapshot) throws -> Data {
        try makeEncoder().encode(snapshot)
    }

    /// Decodes a snapshot, refusing one written by a newer version of
    /// EZLibrary rather than silently dropping the fields it cannot see.
    public static func decode(_ data: Data) throws -> LibrarySnapshot {
        let snapshot: LibrarySnapshot
        do {
            snapshot = try makeDecoder().decode(LibrarySnapshot.self, from: data)
        } catch {
            throw SnapshotError.unreadable
        }
        guard snapshot.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            throw SnapshotError.newerSchema(found: snapshot.schemaVersion)
        }
        return snapshot
    }

    /// `snapshot-<fingerprint>.json`.
    ///
    /// The fingerprint in the name means a device can tell one snapshot from
    /// another without opening it, and — because only the Mac ever writes
    /// files with this prefix — a shared folder never has two writers for the
    /// same file, so iCloud has no cause to create conflict copies.
    public static func fileName(for snapshot: LibrarySnapshot) -> String {
        "snapshot-\(snapshot.libraryFingerprint).json"
    }

    public static func read(contentsOf url: URL) throws -> LibrarySnapshot {
        guard let data = try? Data(contentsOf: url) else {
            throw SnapshotError.missingFile(url.lastPathComponent)
        }
        return try decode(data)
    }

    public enum SnapshotError: Error, LocalizedError, Equatable {
        case missingFile(String)
        case unreadable
        case newerSchema(found: Int)

        public var errorDescription: String? {
            switch self {
            case let .missingFile(name):
                return "Couldn't find the library snapshot \"\(name)\"."
            case .unreadable:
                return "That library snapshot is damaged and couldn't be read."
            case let .newerSchema(found):
                return "That snapshot was made by a newer version of EZLibrary (format \(found))."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .missingFile:
                return "Export a new snapshot from EZLibrary on your Mac."
            case .unreadable:
                return "Export a new snapshot from EZLibrary on your Mac to replace it."
            case .newerSchema:
                return "Update EZLibrary on this device, then open the snapshot again."
            }
        }
    }
}
