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

/// Reproduces the state a library ends up in when files were moved and only
/// `database V2` was rewritten: the SQLite index still names the old paths.
@Suite(.serialized)
struct SeratoLocationRepairServiceTests {

// MARK: - Fixture

private struct Library {
    let root: URL
    let libraryDirectory: URL
    let musicDirectory: URL
    let locationDatabaseURL: URL
    let databaseFileURL: URL
}

/// Builds a `_Serato_` library whose `database V2` names files under
/// `All Music/` while `location.sqlite` still names them one level up.
private func makeDesyncedLibrary(
    fileNames: [String],
    staleSubdirectory: String = "",
    extraDatabaseV2Files: [String] = [],
    filesystemOnlyFiles: [String] = []
) throws -> Library {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-location-repair-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    let musicDirectory = root.appendingPathComponent("Music/All Music", isDirectory: true)

    try FileManager.default.createDirectory(
        at: libraryDirectory.appendingPathComponent("Library", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
    TestBackupDirectory.use()

    let library = Library(
        root: root,
        libraryDirectory: libraryDirectory,
        musicDirectory: musicDirectory,
        locationDatabaseURL: SeratoLocationDatabase.locationDatabaseFile(in: libraryDirectory),
        databaseFileURL: SeratoLibraryLocator.databaseFile(in: libraryDirectory)
    )

    // The files, at their real (current) locations.
    for (index, name) in fileNames.enumerated() {
        let url = musicDirectory.appendingPathComponent(name)
        try Data(String(repeating: "a", count: 100 + index).utf8).write(to: url)
    }
    // Decoys share a filename with a real track but live somewhere else and
    // have a different size, so only file size can tell them apart.
    let decoyDirectory = root.appendingPathComponent("Music/Other", isDirectory: true)
    if !extraDatabaseV2Files.isEmpty {
        try FileManager.default.createDirectory(at: decoyDirectory, withIntermediateDirectories: true)
    }
    for name in extraDatabaseV2Files {
        try Data(String(repeating: "b", count: 4096).utf8)
            .write(to: decoyDirectory.appendingPathComponent(name))
    }

    // database V2: current paths, the way the mover left it. Resolved the
    // same way the service will, or the fixture and the code under test
    // disagree about what the stored paths are relative to.
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: root)
    var databaseData = Data()
    for url in fileNames.map({ musicDirectory.appendingPathComponent($0) })
        + extraDatabaseV2Files.map({ decoyDirectory.appendingPathComponent($0) }) {
        let stored = SeratoLibraryLocator.seratoStoredPath(for: url, rootDirectory: rootDirectory)
        databaseData = SeratoDatabaseWriter.ensuringTrackExists(forStoredPath: stored, in: databaseData).data
    }
    try databaseData.write(to: library.databaseFileURL)

    // Files that sit in the music folder but that `database V2` never got an
    // entry for — a real library had 2931 of these against 1663 in the DB.
    for (index, name) in filesystemOnlyFiles.enumerated() {
        try Data(String(repeating: "c", count: 900 + index).utf8)
            .write(to: musicDirectory.appendingPathComponent(name))
    }

    // location.sqlite: the pre-move paths, still pointing one level up.
    let database = try TestLocationDatabase(at: library.locationDatabaseURL)
    try database.createSeratoSchema()
    let staleAssets = fileNames.map { ($0, false) } + filesystemOnlyFiles.map { ($0, true) }
    for (index, entry) in staleAssets.enumerated() {
        let (name, isFilesystemOnly) = entry
        let stalePath = staleSubdirectory.isEmpty
            ? "Music/\(name)"
            : "Music/\(staleSubdirectory)/\(name)"
        let size = isFilesystemOnly
            ? 900 + index - fileNames.count
            : 100 + index
        try database.insertAsset(
            id: Int64(index + 1),
            portableID: stalePath,
            fileSize: Int64(size)
        )
    }
    database.close()

    return library
}

// MARK: - Tests

@Test func repairsAssetsWhoseFilesMovedWithoutLosingTheirIdentity() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3", "Beta.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    #expect(plan.baseDirectory.standardizedFileURL.path == library.root.standardizedFileURL.path)
    #expect(plan.intactCount == 0)
    #expect(plan.repairs.count == 2)
    #expect(plan.unrepairable.isEmpty)
    #expect(plan.repairs.map(\.newPortableID) == ["Music/All Music/Alpha.mp3", "Music/All Music/Beta.mp3"])

    let result = try SeratoLocationRepairService.apply(plan)
    #expect(result == SeratoLocationRepairService.Result(repairedCount: 2, skippedCount: 0))

    let assets = try SeratoLocationDatabase.assets(in: library.locationDatabaseURL)
    #expect(assets.count == 2)
    // Same rows, new paths: cues and crate membership ride along on asset.id.
    #expect(assets.first(where: { $0.id == 1 })?.portableID == "Music/All Music/Alpha.mp3")
    #expect(assets.first(where: { $0.id == 1 })?.fileName == "Alpha.mp3")
    #expect(assets.first(where: { $0.id == 2 })?.portableID == "Music/All Music/Beta.mp3")
}

@Test func findsFilesThatSitInTheLibraryFolderButNotInDatabaseV2() throws {
    let library = try makeDesyncedLibrary(
        fileNames: ["Alpha.mp3"],
        filesystemOnlyFiles: ["Gamma.mp3"]
    )
    defer { try? FileManager.default.removeItem(at: library.root) }

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    // Searching only what `database V2` names would leave Gamma unrepairable
    // even though it's sitting right next to Alpha.
    #expect(plan.searchRoots.map(\.lastPathComponent) == ["All Music"])
    #expect(plan.repairs.count == 2)
    #expect(plan.unrepairable.isEmpty)
    #expect(plan.repairs.map(\.newPortableID).contains("Music/All Music/Gamma.mp3"))
}

@Test func honoursExplicitSearchRoots() throws {
    let library = try makeDesyncedLibrary(
        fileNames: ["Alpha.mp3"],
        filesystemOnlyFiles: ["Gamma.mp3"]
    )
    defer { try? FileManager.default.removeItem(at: library.root) }

    // An empty root can't turn up Gamma, so only the database V2 track is
    // repairable — proof the caller's roots are what got searched.
    let emptyRoot = library.root.appendingPathComponent("Empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        searchRoots: [emptyRoot],
        homeDirectory: library.root
    )

    #expect(plan.searchRoots == [emptyRoot])
    #expect(plan.repairs.count == 1)
    #expect(try #require(plan.repairs.first).newPortableID == "Music/All Music/Alpha.mp3")
    #expect(plan.unrepairable.count == 1)
}

@Test func planIsAReadOnlyPreview() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    let before = try Data(contentsOf: library.locationDatabaseURL)
    _ = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )
    #expect(try Data(contentsOf: library.locationDatabaseURL) == before)
}

@Test func leavesAssetsAloneWhenTheirPathStillResolves() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let firstPlan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )
    _ = try SeratoLocationRepairService.apply(firstPlan)

    // Re-running finds nothing left to do rather than churning the rows.
    let secondPlan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )
    #expect(secondPlan.intactCount == 1)
    #expect(secondPlan.isEmpty)
}

@Test func reportsAssetsWithNoMatchingFileInsteadOfGuessing() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    let database = try TestLocationDatabase(at: library.locationDatabaseURL)
    try database.insertAsset(id: 99, portableID: "Music/Deleted Long Ago.mp3", fileSize: 7)
    database.close()

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    #expect(plan.repairs.count == 1)
    #expect(plan.unrepairable.count == 1)
    #expect(try #require(plan.unrepairable.first).assetID == 99)
    #expect(try #require(plan.unrepairable.first).reason == .noCandidate)
}

@Test func breaksSameNameTiesByFileSize() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"], extraDatabaseV2Files: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    // Two files named Alpha.mp3 in different folders; only one is 100 bytes,
    // which is the size Serato recorded for asset 1.
    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    #expect(plan.repairs.count == 1)
    #expect(try #require(plan.repairs.first).newPortableID == "Music/All Music/Alpha.mp3")
}

@Test func refusesToChooseBetweenSameNamedFilesOfEqualSize() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"], extraDatabaseV2Files: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    // Make both candidates the same size so size can't break the tie.
    let decoy = library.root.appendingPathComponent("Music/Other/Alpha.mp3")
    try Data(String(repeating: "a", count: 100).utf8).write(to: decoy)

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    #expect(plan.repairs.isEmpty)
    #expect(plan.unrepairable.count == 1)
    #expect(try #require(plan.unrepairable.first).reason == .multipleCandidates(count: 2))
}

@Test func refusesToRepairOntoAFileAnotherAssetAlreadyOwns() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    // A second, stale row for the same filename: repairing both would point
    // two assets at one file and trip the unique index.
    let database = try TestLocationDatabase(at: library.locationDatabaseURL)
    try database.insertAsset(id: 50, portableID: "Music/Old Folder/Alpha.mp3", fileSize: 100)
    database.close()

    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    #expect(plan.repairs.count == 1)
    #expect(plan.unrepairable.count == 1)
    #expect(
        try #require(plan.unrepairable.first).reason
            == .destinationTaken(assetID: #require(plan.repairs.first).assetID)
    )
}

@Test func refusesToApplyWhileSeratoIsRunning() throws {
    let library = try makeDesyncedLibrary(fileNames: ["Alpha.mp3"])
    defer { try? FileManager.default.removeItem(at: library.root) }

    SeratoProcessGuard.isRunningOverride = false
    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: library.libraryDirectory,
        homeDirectory: library.root
    )

    SeratoProcessGuard.isRunningOverride = true
    defer { SeratoProcessGuard.isRunningOverride = nil }

    #expect(throws: SeratoLocationRepairService.RepairError.self) {
        try SeratoLocationRepairService.apply(plan)
    }
}

@Test func throwsWhenTheLibraryHasNoSQLiteIndexToRepair() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-location-repair-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: SeratoLocationRepairService.RepairError.self) {
        try SeratoLocationRepairService.plan(libraryDirectory: libraryDirectory, homeDirectory: root)
    }
}

}

// MARK: - Shared SQLite fixture helper

/// Minimal stand-in for Serato's `location.sqlite` (schema v202), covering
/// the tables and the NOCASE unique index the writer depends on.
final class TestLocationDatabase {
    private var db: OpaquePointer?

    enum TestError: Error { case open, exec(String) }

    init(at url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            throw TestError.open
        }
        db = handle
    }

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
    func insertAsset(id: Int64, portableID: String, revision: Int64 = 100, fileSize: Int64? = nil) throws {
        let escaped = portableID.replacingOccurrences(of: "'", with: "''")
        let fileName = (portableID as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "''")
        let size = fileSize.map(String.init) ?? "NULL"
        try exec("""
            INSERT INTO asset (id, revision, portable_id, file_name, file_size)
                VALUES (\(id), \(revision), '\(escaped)', '\(fileName)', \(size));
            INSERT INTO space_asset (asset_id, space_id) VALUES (\(id), 1);
            """)
    }
}
