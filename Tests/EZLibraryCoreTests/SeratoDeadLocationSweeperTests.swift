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

/// Covers pruning provably-dead disconnected locations from `master.sqlite`.
/// The fixture carries the real `ON DELETE CASCADE` foreign keys and the
/// runtime-only `after_asset_update` trigger, so the cascade delete is
/// exercised exactly as it runs against a live Serato database.
@Suite(.serialized)
struct SeratoDeadLocationSweeperTests {

private struct Env {
    let root: URL
    let applicationSupport: URL
    let masterURL: URL
}

private func record(_ locationID: Int64, _ portableID: String) -> SeratoMasterDatabase.AssetRecord {
    SeratoMasterDatabase.AssetRecord(
        id: 0, locationID: locationID, portableID: portableID,
        fileName: (portableID as NSString).lastPathComponent)
}

/// Builds a master database with one connected location (1) plus whatever
/// disconnected locations the test needs. Each entry is
/// `(locationID, showWhenDisconnected, [(portableID, createFileOnDisk)])`.
private func makeEnvironment(
    disconnected: [(id: Int64, showWhenDisconnected: Bool, assets: [(portableID: String, present: Bool)])],
    connectedExtras: [String] = []
) throws -> Env {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-sweeper-test-\(UUID().uuidString)", isDirectory: true)
    let applicationSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
    let masterDirectory = applicationSupport.appendingPathComponent("Serato/Library", isDirectory: true)
    try FileManager.default.createDirectory(at: masterDirectory, withIntermediateDirectories: true)
    TestBackupDirectory.use()

    let masterURL = masterDirectory.appendingPathComponent("master.sqlite")
    let database = try TestLocationDatabase(at: masterURL)
    try database.exec("""
        CREATE TABLE location (
            id INTEGER PRIMARY KEY,
            path TEXT,
            revision INT NOT NULL DEFAULT 0,
            show_when_disconnected INT NOT NULL DEFAULT 0
        );
        CREATE TABLE connection (location_id INTEGER PRIMARY KEY NOT NULL, database_uri TEXT NOT NULL);
        CREATE TABLE asset (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            location_id INTEGER NOT NULL,
            portable_id TEXT NOT NULL DEFAULT '',
            file_name TEXT DEFAULT NULL,
            file_name_norm TEXT DEFAULT NULL,
            FOREIGN KEY(location_id) REFERENCES location(id) ON DELETE CASCADE
        );
        INSERT INTO location (id) VALUES (1);
        INSERT INTO connection (location_id, database_uri) VALUES (1, '/tmp/connected.sqlite');
        INSERT INTO asset (id, location_id, portable_id, file_name)
            VALUES (10, 1, 'Music/All Music/Connected.mp3', 'Connected.mp3');
        """)

    // The runtime-only trigger the app must never provoke. Present so a
    // cascade delete that mistakenly fired it would fail loudly here.
    try database.exec("""
        CREATE TRIGGER after_asset_update
        AFTER UPDATE OF file_name ON asset
        BEGIN
            UPDATE asset SET file_name_norm = serato_str_norm( file_name ) WHERE asset.id = old.id;
        END;
        """)

    var nextID: Int64 = 100
    for location in disconnected {
        try database.exec(
            "INSERT INTO location (id, show_when_disconnected) VALUES "
            + "(\(location.id), \(location.showWhenDisconnected ? 1 : 0));")
        for asset in location.assets {
            let escaped = asset.portableID.replacingOccurrences(of: "'", with: "''")
            let base = (asset.portableID as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "''")
            try database.exec("""
                INSERT INTO asset (id, location_id, portable_id, file_name)
                    VALUES (\(nextID), \(location.id), '\(escaped)', '\(base)');
                """)
            nextID += 1
            if asset.present {
                let fileURL = root.appendingPathComponent(asset.portableID)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("audio".utf8).write(to: fileURL)
            }
        }
    }
    // Extra files the connected location (1) also carries, for redundancy tests.
    for portableID in connectedExtras {
        let escaped = portableID.replacingOccurrences(of: "'", with: "''")
        let base = (portableID as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "''")
        try database.exec("""
            INSERT INTO asset (id, location_id, portable_id, file_name)
                VALUES (\(nextID), 1, '\(escaped)', '\(base)');
            """)
        nextID += 1
    }
    database.close()

    return Env(root: root, applicationSupport: applicationSupport, masterURL: masterURL)
}

// MARK: - Classification

@Test func classifiesStreamingOnlyLocationAsDead() {
    let assets = [
        record(5, "streaming:spotify:track:abc"),
        record(5, "streaming:tidal:track:xyz")
    ]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: [], homeDirectory: URL(fileURLWithPath: "/nope"), fileManager: .default) == .streamingOnly)
}

@Test func classifiesAllMissingFileLocationAsDead() {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweeper-missing-\(UUID().uuidString)", isDirectory: true)
    let assets = [record(5, "Music/Gone One.mp3"), record(5, "Music/Gone Two.mp3")]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: [], homeDirectory: home, fileManager: .default) == .allFilesMissing)
}

@Test func keepsLocationWhenAnyFileStillResolves() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweeper-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let present = home.appendingPathComponent("Music/Here.mp3")
    try FileManager.default.createDirectory(
        at: present.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: present)

    let assets = [record(5, "Music/Here.mp3"), record(5, "Music/Gone.mp3")]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: [], homeDirectory: home, fileManager: .default) == nil)
}

@Test func keepsLocationThatNamesAnExternalVolume() {
    // Could be a drive that is merely unplugged — never auto-remove.
    let assets = [record(5, "Volumes/USB DRIVE/Music/Track.mp3")]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: [], homeDirectory: URL(fileURLWithPath: "/nope"), fileManager: .default) == nil)
}

@Test func classifiesEmptyLocationAsDead() {
    #expect(SeratoDeadLocationSweeper.classify(
        [], connectedPaths: [], homeDirectory: URL(fileURLWithPath: "/nope"), fileManager: .default) == .empty)
}

@Test func classifiesRedundantDuplicateLocationAsDead() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweeper-redundant-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let shared = home.appendingPathComponent("Music/Shared.mp3")
    try FileManager.default.createDirectory(
        at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: shared)

    // The connected library already carries this exact file, so the only live
    // file in the location is a duplicate -> safe to remove.
    let connected: Set<String> = [shared.path]
    let assets = [record(5, "Music/Shared.mp3"), record(5, "Music/Gone.mp3")]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: connected, homeDirectory: home, fileManager: .default) == .redundantDuplicate)
}

@Test func keepsLocationWithAUniqueLiveFileTheConnectedLibraryLacks() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweeper-unique-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let unique = home.appendingPathComponent("Music/OnlyHere.mp3")
    try FileManager.default.createDirectory(
        at: unique.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: unique)

    // Connected library has something else, not this file.
    let connected: Set<String> = ["/somewhere/Else.mp3"]
    let assets = [record(5, "Music/OnlyHere.mp3")]
    #expect(SeratoDeadLocationSweeper.classify(
        assets, connectedPaths: connected, homeDirectory: home, fileManager: .default) == nil)
}

// MARK: - Plan

@Test func planFlagsDeadLocationsAndKeepsTheRest() throws {
    let env = try makeEnvironment(disconnected: [
        (id: 4, showWhenDisconnected: false, assets: [
            (portableID: "streaming:spotify:track:a", present: false),
            (portableID: "streaming:spotify:track:b", present: false)
        ]),
        (id: 5, showWhenDisconnected: false, assets: [
            (portableID: "Music/Old One.mp3", present: false),
            (portableID: "Music/Old Two.mp3", present: false)
        ]),
        (id: 6, showWhenDisconnected: false, assets: [
            (portableID: "Music/Still Here.mp3", present: true)   // live -> keep
        ]),
        (id: 7, showWhenDisconnected: true, assets: [             // user kept -> keep
            (portableID: "Music/Gone.mp3", present: false)
        ])
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let plan = try SeratoDeadLocationSweeper.plan(
        applicationSupportDirectory: env.applicationSupport, homeDirectory: env.root)

    #expect(plan.dead.map(\.locationID) == [4, 5])
    #expect(plan.removableAssetCount == 4)
    #expect(plan.keptDisconnectedIDs == [6, 7])
}

@Test func planFlagsARedundantDuplicateLocation() throws {
    let env = try makeEnvironment(
        disconnected: [
            (id: 8, showWhenDisconnected: false, assets: [
                (portableID: "Music/All Music/Dup.mp3", present: true)
            ])
        ],
        connectedExtras: ["Music/All Music/Dup.mp3"]   // same file lives in the connected library
    )
    defer { try? FileManager.default.removeItem(at: env.root) }

    let plan = try SeratoDeadLocationSweeper.plan(
        applicationSupportDirectory: env.applicationSupport, homeDirectory: env.root)

    #expect(plan.dead.map(\.locationID) == [8])
    #expect(plan.dead.first?.reason == .redundantDuplicate)
    #expect(plan.keptDisconnectedIDs.isEmpty)
}

// MARK: - Apply

@Test func applyRemovesDeadLocationsAndCascadesTheirAssets() throws {
    let env = try makeEnvironment(disconnected: [
        (id: 4, showWhenDisconnected: false, assets: [
            (portableID: "streaming:spotify:track:a", present: false)
        ]),
        (id: 5, showWhenDisconnected: false, assets: [
            (portableID: "Music/Old One.mp3", present: false),
            (portableID: "Music/Old Two.mp3", present: false)
        ])
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }
    TestSeratoEnvironment.pretendSeratoIsClosed()

    let plan = try SeratoDeadLocationSweeper.plan(
        applicationSupportDirectory: env.applicationSupport, homeDirectory: env.root)
    let summary = try SeratoDeadLocationSweeper.apply(plan)

    #expect(summary.removedLocationCount == 2)
    #expect(summary.removedAssetCount == 3)

    // The dead locations and their assets are gone; the connected one stays.
    #expect(try SeratoMasterDatabase.disconnectedLocationIDs(in: env.masterURL).isEmpty)
    #expect(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 4).isEmpty)
    #expect(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 5).isEmpty)
    #expect(try SeratoMasterDatabase.assets(in: env.masterURL, locationID: 1).count == 1)

    // No dangling asset rows or broken foreign keys were left behind.
    let check = try TestLocationDatabase(at: env.masterURL)
    defer { check.close() }
    #expect(try check.queryInt("PRAGMA foreign_key_check") == nil)
    #expect(try check.queryString("PRAGMA integrity_check") == "ok")
}

@Test func applyRefusesWhileSeratoIsRunning() throws {
    let env = try makeEnvironment(disconnected: [
        (id: 5, showWhenDisconnected: false, assets: [
            (portableID: "Music/Old.mp3", present: false)
        ])
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let plan = try SeratoDeadLocationSweeper.plan(
        applicationSupportDirectory: env.applicationSupport, homeDirectory: env.root)

    TestSeratoEnvironment.withSeratoRunning {
        #expect(throws: SeratoDeadLocationSweeper.SweepError.seratoIsRunning) {
            try SeratoDeadLocationSweeper.apply(plan)
        }
    }

    // Nothing was deleted.
    #expect(try SeratoMasterDatabase.disconnectedLocationIDs(in: env.masterURL) == [5])
}

}
