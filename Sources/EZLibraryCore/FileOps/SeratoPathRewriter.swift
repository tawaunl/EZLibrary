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

/// The single choke point every feature should use to rewrite a track's
/// stored path. Composes the Safety/ primitives in the correct order —
/// nothing else should call `AtomicFileWriter` or `SeratoDatabaseWriter`
/// directly for this purpose.
///
/// A path change has to land in *both* of Serato's libraries: `database V2`
/// and `Library/location.sqlite`. Modern Serato reads the SQLite one, so
/// updating only `database V2` leaves the track showing as missing — see
/// `SeratoLocationDatabase` for the details.
public enum SeratoPathRewriter {
    public enum RewriteError: Error, Equatable {
        /// Refuse to write while Serato itself might also be writing to
        /// the same file.
        case seratoIsRunning
        /// `oldPath` didn't match any track — failing loud here (rather
        /// than silently writing back identical bytes) surfaces caller
        /// bugs immediately instead of a mysterious no-op.
        case trackNotFound
    }

    @discardableResult
    public static func rewritePaths(
        _ rewrites: [String: String],
        in databaseFileURL: URL
    ) throws -> Int {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RewriteError.seratoIsRunning
        }
        guard !rewrites.isEmpty else {
            return 0
        }

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)

        let data = try Data(contentsOf: databaseFileURL)
        let rewritten = SeratoDatabaseWriter.rewritingPaths(rewrites, in: data)
        guard rewritten.rewrittenCount > 0 else {
            throw RewriteError.trackNotFound
        }

        // SQLite goes first because it's the half that can fail cleanly: its
        // transaction either commits or rolls back, leaving `database V2`
        // untouched and the two libraries still agreeing with each other.
        let libraryDirectory = databaseFileURL.deletingLastPathComponent()
        let locationDatabaseURL = SeratoLocationDatabase.locationDatabaseFile(in: libraryDirectory)
        try SeratoLocationDatabase.rewritePaths(
            rewrites,
            rootDirectory: SeratoLibraryLocator.rootDirectory(for: libraryDirectory),
            in: locationDatabaseURL
        )

        do {
            try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)
        } catch {
            revertLocationDatabase(rewrites, libraryDirectory: libraryDirectory, locationDatabaseURL: locationDatabaseURL)
            throw error
        }

        return rewritten.rewrittenCount
    }

    /// Best-effort undo of the SQLite half when the `database V2` write that
    /// should have followed it fails. A failure here is swallowed: the caller
    /// is already throwing, and the pre-write snapshot is the backstop.
    private static func revertLocationDatabase(
        _ rewrites: [String: String],
        libraryDirectory: URL,
        locationDatabaseURL: URL
    ) {
        let inverse = Dictionary(rewrites.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        _ = try? SeratoLocationDatabase.rewritePaths(
            inverse,
            rootDirectory: SeratoLibraryLocator.rootDirectory(for: libraryDirectory),
            in: locationDatabaseURL
        )
    }

    @discardableResult
    public static func rewritePath(
        _ oldPath: String,
        to newPath: String,
        in databaseFileURL: URL
    ) throws -> Bool {
        try rewritePaths([oldPath: newPath], in: databaseFileURL) > 0
    }
}
