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

/// Covers `master.sqlite`, Serato's aggregate library — including the
/// `after_asset_update` trigger that calls a function only Serato's own
/// process registers.
@Suite(.serialized)
struct SeratoMasterDatabaseTests {

private struct Env {
    let root: URL
    let applicationSupport: URL
    let libraryDirectory: URL
    let musicDirectory: URL
    let masterURL: URL
}

/// Builds an aggregate database with one connected location and one
/// disconnected location whose rows point at a folder the files have left.
private func makeEnvironment(
    movedFiles: [String] = ["Alpha.mp3"],
    deletedFiles: [String] = [],
    streamingIDs: [String] = []
) throws -> Env {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-master-test-\(UUID().uuidString)", isDirectory: true)
    let applicationSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    let musicDirectory = root.appendingPathComponent("Music/All Music", isDirectory: true)
    let masterDirectory = applicationSupport
        .appendingPathComponent("Serato/Library", isDirectory: true)

    for directory in [masterDirectory, libraryDirectory, musicDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    TestBackupDirectory.use()

    // Files at their current home.
    for name in movedFiles {
        try Data("audio".utf8).write(to: musicDirectory.appendingPathComponent(name))
    }

    // database V2 names the current locations, so the scan roots resolve.
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: root)
    var databaseData = Data()
    for name in movedFiles {
        let stored = SeratoLibraryLocator.seratoStoredPath(
            for: musicDirectory.appendingPathComponent(name), rootDirectory: rootDirectory)
        databaseData = SeratoDatabaseWriter.ensuringTrackExists(forStoredPath: stored, in: databaseData).data
    }
    try databaseData.write(to: SeratoLibraryLocator.databaseFile(in: libraryDirectory))

    let masterURL = masterDirectory.appendingPathComponent("master.sqlite")
    let database = try TestLocationDatabase(at: masterURL)
    try database.exec("""
        CREATE TABLE location (id INTEGER PRIMARY KEY, path TEXT, revision INT NOT NULL DEFAULT 0);
        CREATE TABLE connection (location_id INTEGER, database_uri TEXT);
        CREATE TABLE asset (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            location_id INTEGER NOT NULL,
            portable_id TEXT NOT NULL DEFAULT '',
            file_name TEXT DEFAULT NULL,
            file_name_norm TEXT DEFAULT NULL
        );
        CREATE UNIQUE INDEX asset__unique_database
            ON asset ( location_id, portable_id COLLATE NOCASE );
        INSERT INTO location (id) VALUES (1), (5);
        INSERT INTO connection (location_id, database_uri) VALUES (1, '/tmp/connected.sqlite');
        """)

    // Serato's real trigger fires on file_name and calls serato_str_norm(),
    // which only exists inside Serato. Recreating it here is the point: a
    // write that touches file_name must fail exactly like it does in the app.
    try database.exec("""
        CREATE TRIGGER after_asset_update
        AFTER UPDATE OF file_name ON asset
        BEGIN
            UPDATE asset SET file_name_norm = serato_str_norm( file_name ) WHERE asset.id = old.id;
        END;
        """)

    var nextID: Int64 = 100
    func insert(locationID: Int64, portableID: String) throws {
        let escaped = portableID.replacingOccurrences(of: "'", with: "''")
        let base = (portableID as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "''")
        try database.exec("""
            INSERT INTO asset (id, location_id, portable_id, file_name, file_name_norm)
                VALUES (\(nextID), \(locationID), '\(escaped)', '\(base)', lower('\(base)'));
            """)
        nextID += 1
    }
    // Disconnected location 5: stale paths one folder up from the real files.
    for name in movedFiles { try insert(locationID: 5, portableID: "Music/\(name)") }
    for name in deletedFiles { try insert(locationID: 5, portableID: "Music/\(name)") }
    for identifier in streamingIDs { try insert(locationID: 5, portableID: identifier) }
    // Connected location 1 already holds correct paths.
    for name in movedFiles { try insert(locationID: 1, portableID: "Music/All Music/\(name)") }
    database.close()

    return Env(
        root: root,
        applicationSupport: applicationSupport,
        libraryDirectory: libraryDirectory,
        musicDirectory: musicDirectory,
        masterURL: masterURL
    )
}

@Test func findsLocationsSeratoNoLongerSyncs() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    #expect(try SeratoMasterDatabase.disconnectedLocationIDs(in: env.masterURL) == [5])
}

@Test func repairsGhostRowsInDisconnectedLocations() throws {
    let env = try makeEnvironment(movedFiles: ["Alpha.mp3", "Beta.mp3"])
    defer { try? FileManager.default.removeItem(at: env.root) }

    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    let plan = try SeratoLocationRepairService.planDisconnectedLocations(
        libraryDirectory: env.libraryDirectory,
        applicationSupportDirectory: env.applicationSupport,
        homeDirectory: env.root
    )

    #expect(plan.repairs.count == 2)
    #expect(plan.needsSeratoRuntimeCount == 0)
    #expect(plan.repairs.map(\.newPortableID).sorted()
        == ["Music/All Music/Alpha.mp3", "Music/All Music/Beta.mp3"])

    let result = try SeratoLocationRepairService.apply(plan)
    #expect(result.repairedCount == 2)

    let repaired = try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5)
    #expect(repaired.allSatisfy { FileManager.default.fileExists(
        atPath: env.root.appendingPathComponent($0.portableID).path) })
    // The connected location keeps its own rows; nothing is merged.
    #expect(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 1).count == 2)
}

@Test func leavesRowsWhoseFileIsGenuinelyGone() throws {
    let env = try makeEnvironment(movedFiles: ["Alpha.mp3"], deletedFiles: ["Vanished.mp3"])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let plan = try SeratoLocationRepairService.planDisconnectedLocations(
        libraryDirectory: env.libraryDirectory,
        applicationSupportDirectory: env.applicationSupport,
        homeDirectory: env.root
    )

    #expect(plan.repairs.count == 1)
    #expect(plan.unresolvedCount == 1)
}

@Test func ignoresStreamingAssetsThatAreNotFiles() throws {
    let env = try makeEnvironment(
        movedFiles: ["Alpha.mp3"],
        streamingIDs: ["streaming:spotify:track:abc123", "streaming:tidal:track:xyz"]
    )
    defer { try? FileManager.default.removeItem(at: env.root) }

    let plan = try SeratoLocationRepairService.planDisconnectedLocations(
        libraryDirectory: env.libraryDirectory,
        applicationSupportDirectory: env.applicationSupport,
        homeDirectory: env.root
    )

    // Streaming rows have no file to find; counting them as broken would
    // bury the real number under thousands of false positives.
    #expect(plan.repairs.count == 1)
    #expect(plan.unresolvedCount == 0)
}

@Test func refusesAnyWriteThatWouldNeedSeratosOwnSQLFunctions() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let ghost = try #require(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5).first)

    // Renaming the file too would mean writing `file_name`, which trips
    // `after_asset_update` -> serato_str_norm() and fails outside Serato.
    #expect(throws: SeratoMasterDatabase.MasterError.self) {
        try SeratoMasterDatabase.rewritePortableIDs(
            [(id: ghost.id, portableID: "Music/All Music/Different Name.mp3")],
            in: env.masterURL
        )
    }

    // And the row is left exactly as it was.
    let after = try #require(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5).first)
    #expect(after.portableID == ghost.portableID)
}

@Test func writingOnlyPortableIDDoesNotFireTheTrigger() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }

    let ghost = try #require(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5).first)
    let updated = try SeratoMasterDatabase.rewritePortableIDs(
        [(id: ghost.id, portableID: "Music/All Music/Alpha.mp3")],
        in: env.masterURL
    )

    #expect(updated == 1)
    let after = try #require(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5).first)
    #expect(after.portableID == "Music/All Music/Alpha.mp3")
    #expect(after.fileName == "Alpha.mp3")
}

}
