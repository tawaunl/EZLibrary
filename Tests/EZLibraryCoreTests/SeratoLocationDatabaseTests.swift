// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
import SQLite3
@testable import EZLibraryCore

/// Fixtures here mirror the subset of Serato DJ Pro's `location.sqlite`
/// schema (v202) that the rewriter touches: the `asset` row plus the
/// `serato`/`space`/`space_asset` tables its revision bookkeeping reads.
@Suite(.serialized)
struct SeratoLocationDatabaseTests {

// MARK: - Fixture helpers

private final class TestDatabase {
    let url: URL
    private var db: OpaquePointer?

    init(at url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            throw TestError.open
        }
        db = handle
    }

    enum TestError: Error { case open, exec(String), noRow }

    func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw TestError.exec(message)
        }
    }

    func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    func queryString(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestError.exec(sql) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func queryInt(_ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TestError.exec(sql) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// Applies the tables and the NOCASE unique index the rewriter relies on.
    func createSeratoSchema(revision: Int64 = 500) throws {
        try exec("""
            CREATE TABLE serato (
                database_name TEXT DEFAULT '',
                time_created INTEGER NOT NULL,
                time_last_connected INTEGER DEFAULT NULL,
                last_master_uuid BLOB DEFAULT NULL,
                revision INT DEFAULT 0
            );
            CREATE TABLE space (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0,
                UNIQUE(name COLLATE NOCASE)
            );
            CREATE TABLE asset (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                revision INTEGER NOT NULL,
                portable_id TEXT NOT NULL DEFAULT '',
                file_name TEXT DEFAULT NULL,
                file_size INTEGER,
                artist TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                is_missing INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX asset__unique_portable_id ON asset ( portable_id COLLATE NOCASE );
            CREATE TABLE space_asset (
                id INTEGER PRIMARY KEY,
                asset_id INTEGER NOT NULL,
                space_id INTEGER NOT NULL,
                UNIQUE(asset_id, space_id)
            );
            INSERT INTO serato (time_created, revision) VALUES (1, \(revision));
            INSERT INTO space (id, name, revision) VALUES (1, 'Serato Library', \(revision - 100));
            """)
    }

    /// Inserts an asset and files it under space 1, the way Serato does for
    /// every track in the main library.
    func insertAsset(id: Int64, portableID: String, revision: Int64 = 100) throws {
        let escaped = portableID.replacingOccurrences(of: "'", with: "''")
        let fileName = (portableID as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "''")
        try exec("""
            INSERT INTO asset (id, revision, portable_id, file_name)
                VALUES (\(id), \(revision), '\(escaped)', '\(fileName)');
            INSERT INTO space_asset (asset_id, space_id) VALUES (\(id), 1);
            """)
    }
}

private struct Environment {
    let root: URL
    let libraryDirectory: URL
    let locationDatabaseURL: URL
}

private func makeEnvironment() throws -> Environment {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-location-db-test-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    try FileManager.default.createDirectory(
        at: libraryDirectory.appendingPathComponent("Library", isDirectory: true),
        withIntermediateDirectories: true
    )
    SeratoBackupBeforeWrite.backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
    return Environment(
        root: root,
        libraryDirectory: libraryDirectory,
        locationDatabaseURL: SeratoLocationDatabase.locationDatabaseFile(in: libraryDirectory)
    )
}

// MARK: - Tests

@Test func rewritesPortableIDAndFileNameForVolumeRelativeLibrary() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 7, portableID: "Music/Old Name.mp3")
    database.close()

    let summary = try SeratoLocationDatabase.rewritePaths(
        ["Music/Old Name.mp3": "Music/Artist-Title.mp3"],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    #expect(summary.updatedCount == 1)
    #expect(summary.unmatchedPaths.isEmpty)
    #expect(summary.conflictingPaths.isEmpty)

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(try reopened.queryString("SELECT portable_id FROM asset WHERE id = 7") == "Music/Artist-Title.mp3")
    #expect(try reopened.queryString("SELECT file_name FROM asset WHERE id = 7") == "Artist-Title.mp3")
}

@Test func keepsAssetIDSoCuesAndCrateMembershipSurvive() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 42, portableID: "Music/Old Name.mp3")
    database.close()

    _ = try SeratoLocationDatabase.rewritePaths(
        ["Music/Old Name.mp3": "Music/New Name.mp3"],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    // A rename must be an in-place edit: everything Serato attaches to a
    // track (cues, beat grid, play count, crate membership) is keyed on
    // `asset.id`, so a delete-and-reinsert would silently drop all of it.
    #expect(try reopened.queryInt("SELECT COUNT(*) FROM asset") == 1)
    #expect(try reopened.queryInt("SELECT id FROM asset WHERE portable_id = 'Music/New Name.mp3'") == 42)
    #expect(try reopened.queryInt("SELECT COUNT(*) FROM space_asset WHERE asset_id = 42 AND space_id = 1") == 1)
}

@Test func raisesAssetAndSpaceRevisionsToTheCurrentGlobalRevision() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema(revision: 900)
    try database.insertAsset(id: 3, portableID: "Music/Old Name.mp3", revision: 120)
    database.close()

    _ = try SeratoLocationDatabase.rewritePaths(
        ["Music/Old Name.mp3": "Music/New Name.mp3"],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(try reopened.queryInt("SELECT revision FROM asset WHERE id = 3") == 900)
    #expect(try reopened.queryInt("SELECT revision FROM space WHERE id = 1") == 900)
    // The global counter is Serato's to advance; we only stamp rows with it.
    #expect(try reopened.queryInt("SELECT revision FROM serato") == 900)
}

@Test func matchesHomeRelativePortableIDsForBootVolumeLibraries() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // A boot-volume library resolves against "/", but Serato writes portable
    // IDs relative to the home directory — the case that made every track in
    // a real library look missing after a path rewrite.
    let home = env.root.appendingPathComponent("Users/dj", isDirectory: true)
    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 11, portableID: "Music/All Music/Old Name.mp3")
    database.close()

    let summary = try SeratoLocationDatabase.rewritePaths(
        [
            "Users/dj/Music/All Music/Old Name.mp3":
                "Users/dj/Music/All Music/Artist-Title.mp3"
        ],
        rootDirectory: env.root,
        in: env.locationDatabaseURL,
        homeDirectory: home
    )

    #expect(summary.updatedCount == 1)

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(
        try reopened.queryString("SELECT portable_id FROM asset WHERE id = 11")
            == "Music/All Music/Artist-Title.mp3"
    )
}

@Test func reportsPathsWithNoMatchingAssetInsteadOfFailing() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 1, portableID: "Music/Known.mp3")
    database.close()

    let summary = try SeratoLocationDatabase.rewritePaths(
        [
            "Music/Known.mp3": "Music/Known Renamed.mp3",
            "Music/Never Seen.mp3": "Music/Never Seen Renamed.mp3"
        ],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    #expect(summary.updatedCount == 1)
    #expect(summary.unmatchedPaths == ["Music/Never Seen.mp3"])
}

@Test func skipsRewriteWhenAnotherAssetAlreadyClaimsTheDestination() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 1, portableID: "Music/Old Name.mp3")
    try database.insertAsset(id: 2, portableID: "Music/Taken.mp3")
    database.close()

    let summary = try SeratoLocationDatabase.rewritePaths(
        ["Music/Old Name.mp3": "Music/Taken.mp3"],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    // Forcing the update would trip `asset__unique_portable_id` and abort the
    // whole transaction, taking every other rename in the batch with it.
    #expect(summary.updatedCount == 0)
    #expect(summary.conflictingPaths == ["Music/Old Name.mp3"])

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(try reopened.queryString("SELECT portable_id FROM asset WHERE id = 1") == "Music/Old Name.mp3")
}

@Test func isANoOpWhenTheLibraryHasNoLocationDatabase() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    // Serato 2.x libraries have no `location.sqlite`; a rewrite there must
    // still succeed on `database V2` alone rather than throwing.
    let summary = try SeratoLocationDatabase.rewritePaths(
        ["Music/Old Name.mp3": "Music/New Name.mp3"],
        rootDirectory: env.root,
        in: env.locationDatabaseURL
    )

    #expect(summary == .empty)
}

@Test func refusesToWriteToAFileThatIsNotALocationDatabase() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.exec("CREATE TABLE unrelated (id INTEGER PRIMARY KEY);")
    database.close()

    #expect(throws: SeratoLocationDatabase.LocationError.unsupportedSchema) {
        try SeratoLocationDatabase.rewritePaths(
            ["Music/Old Name.mp3": "Music/New Name.mp3"],
            rootDirectory: env.root,
            in: env.locationDatabaseURL
        )
    }
}

@Test func pathRewriterUpdatesBothLibrariesInOnePass() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let fixtureRoot = Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
    let databaseFileURL = env.libraryDirectory.appendingPathComponent("database V2")
    try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("database V2"), to: databaseFileURL)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFileURL, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)
    let oldStoredPath = target.seratoStoredPath
    let newStoredPath = oldStoredPath.replacingOccurrences(
        of: target.fileURL.lastPathComponent,
        with: "Renamed By Test.mp3"
    )
    let oldPortableID = SeratoLibraryLocator.seratoStoredPath(for: target.fileURL, rootDirectory: env.root)

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 5, portableID: oldPortableID)
    database.close()

    let rewrittenCount = try SeratoPathRewriter.rewritePaths(
        [oldStoredPath: newStoredPath],
        in: databaseFileURL
    )
    #expect(rewrittenCount == 1)

    let reparsed = try SeratoDatabaseParser.parseTracks(at: databaseFileURL, rootDirectory: rootDirectory)
    #expect(reparsed.contains { $0.seratoStoredPath == newStoredPath })

    let expectedPortableID = (oldPortableID as NSString)
        .deletingLastPathComponent
        .appending("/Renamed By Test.mp3")
    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(try reopened.queryString("SELECT portable_id FROM asset WHERE id = 5") == expectedPortableID)
}

@Test func renamingFromMetadataKeepsSeratoPointedAtTheFile() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let fixtureRoot = Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
    let databaseFileURL = env.libraryDirectory.appendingPathComponent("database V2")
    try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("database V2"), to: databaseFileURL)
    try FileManager.default.copyItem(
        at: fixtureRoot.appendingPathComponent("Subcrates"),
        to: env.libraryDirectory.appendingPathComponent("Subcrates")
    )

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFileURL, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)
    let oldPortableID = SeratoLibraryLocator.seratoStoredPath(for: target.fileURL, rootDirectory: env.root)

    let database = try TestDatabase(at: env.locationDatabaseURL)
    try database.createSeratoSchema()
    try database.insertAsset(id: 9, portableID: oldPortableID)
    database.close()

    try FileManager.default.createDirectory(
        at: target.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("audio".utf8).write(to: target.fileURL)

    let metadata = SeratoTrackMetadataUpdate(
        title: "Renamed Title",
        artist: "Renamed Artist",
        album: "",
        genre: "",
        comment: target.comment,
        key: target.key ?? "",
        bpm: target.bpm,
        year: nil
    )
    try SeratoTrackMetadataEditor.update(
        track: target,
        metadata: metadata,
        databaseFileURL: databaseFileURL,
        rewriteFilenameFromMetadata: true
    )

    let renamedFileName = "Renamed Artist-Renamed Title.\(target.fileURL.pathExtension)"
    let expectedPortableID = (oldPortableID as NSString)
        .deletingLastPathComponent
        .appending("/\(renamedFileName)")

    // The point of the whole exercise: the file on disk, `database V2` and
    // `location.sqlite` all name the same path afterwards.
    let renamedFileURL = target.fileURL.deletingLastPathComponent().appendingPathComponent(renamedFileName)
    #expect(FileManager.default.fileExists(atPath: renamedFileURL.path))

    let reparsed = try SeratoDatabaseParser.parseTracks(at: databaseFileURL, rootDirectory: rootDirectory)
    let expectedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: renamedFileURL, rootDirectory: rootDirectory)
    #expect(reparsed.contains { $0.seratoStoredPath == expectedStoredPath })

    let reopened = try TestDatabase(at: env.locationDatabaseURL)
    defer { reopened.close() }
    #expect(try reopened.queryString("SELECT portable_id FROM asset WHERE id = 9") == expectedPortableID)
    #expect(try reopened.queryInt("SELECT COUNT(*) FROM asset") == 1)
}

}
