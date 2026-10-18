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
import Testing
@testable import EZLibraryCore

private func scratchDatabase() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("onelib-\(UUID().uuidString).db")
}

private func sampleTracks() -> [CDJExportTrack] {
    [
        CDJExportTrack(
            id: 1, title: "Alpha", artist: "Ann", album: "First", genre: "House", label: "Lbl", comment: "hi",
            year: 2020, durationSeconds: 200, bpm: 124.5, bitrate: 320, sampleRate: 44_100, fileSize: 5_000,
            trackNumber: 3, fileType: .mp3, stickPath: "/Contents/Ann/First/alpha.mp3", dateAdded: "2026-01-02",
            analyzePath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT"),
        CDJExportTrack(
            id: 2, title: "Beta", artist: "Ann", album: "First", genre: "House", fileType: .wav,
            stickPath: "/Contents/Ann/First/beta.wav", dateAdded: "", analyzePath: "")
    ]
}

private func sampleAnalysis() -> [UInt32: SeratoTrackAnalysis] {
    [1: SeratoTrackAnalysis(
        cues: [
            .init(index: 0, positionMs: 1_000, color: .init(red: 0xFF, green: 0, blue: 0), name: "A"),
            .init(index: 3, positionMs: 2_500, color: .init(red: 0, green: 0xFF, blue: 0), name: "D")],
        loops: [.init(index: 0, startMs: 4_000, endMs: 6_000, color: .init(red: 0, green: 0, blue: 0xFF), name: "L")])]
}

private func write(
    _ url: URL, settings: OneLibrarySettings = .defaults, playlists: [CDJExportPlaylist]? = nil
) throws {
    try OneLibraryWriter.write(
        to: url, tracks: sampleTracks(),
        playlists: playlists ?? [
            CDJExportPlaylist(id: 1, name: "Folder", isFolder: true),
            CDJExportPlaylist(id: 2, parentID: 1, name: "Set", sortOrder: 0, trackIDs: [2, 1])
        ],
        analyses: sampleAnalysis(), deviceName: "STICK", createdDate: "2026-10-18", libraryID: 777, settings: settings)
}

private func open(_ url: URL) throws -> CDJSQLiteDatabase {
    try CDJSQLiteDatabase(url: url, passphrase: OneLibraryKey.passphrase(), readOnly: true)
}

@Test func theSharedPassphraseDerivesAndPassesItsOwnCheck() throws {
    let passphrase = try OneLibraryKey.passphrase()
    #expect(passphrase.hasPrefix("r8gd"))
    #expect(!passphrase.isEmpty)
}

@Test func databaseIsEncryptedAndNeedsTheKey() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)

    // Plain SQLite starts with a readable header; an encrypted file doesn't.
    let header = try Data(contentsOf: url).prefix(16)
    #expect(String(data: header, encoding: .utf8)?.hasPrefix("SQLite format 3") != true)
    // No journal beside it.
    #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: url.path + "-journal"))

    let wrong = try CDJSQLiteDatabase(url: url, passphrase: "not the key", readOnly: true)
    #expect(throws: (any Error).self) { try wrong.rows("SELECT COUNT(*) FROM content", columns: 1) }
    #expect(try open(url).rows("SELECT COUNT(*) FROM content", columns: 1).first?.first == .int(2))
}

@Test func schemaBrowseRowsAndPropertyMatchTheReference() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)
    let database = try open(url)

    let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'", columns: 1)
    #expect(tables.count == 22)
    #expect(try database.rows("SELECT COUNT(*) FROM menuItem", columns: 1).first?.first == .int(27))
    #expect(try database.rows("SELECT COUNT(*) FROM category", columns: 1).first?.first == .int(22))
    #expect(try database.rows("SELECT COUNT(*) FROM sort", columns: 1).first?.first == .int(17))
    // Menu names are wrapped in the annotation markers so players translate them.
    let genre = try database.rows("SELECT name FROM menuItem WHERE menuItem_id = 1", columns: 1).first?.first
    #expect(genre == .text("\u{FFFA}GENRE\u{FFFB}"))
    let colours = try database.rows("SELECT name FROM color ORDER BY color_id", columns: 1).compactMap { $0[0].textValue }
    #expect(colours == ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"])

    let property = try #require(try database.rows(
        "SELECT deviceName, dbVersion, numberOfContents, createdDate, backGroundColorType, myTagMasterDBID FROM property",
        columns: 6).first)
    #expect(property == [.text("STICK"), .text("1000"), .int(2), .text("2026-10-18"), .int(0), .int(777)])
}

@Test func tracksCarryTheirMetadataAndMatchExportPdbIDs() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)
    let database = try open(url)

    let alpha = try #require(try database.rows(
        """
        SELECT title, bpmx100, length, trackNo, path, fileName, fileSize, fileType, bitrate, samplingRate,
               analysisDataFilePath, isHotCueAutoLoadOn, masterDbId, masterContentId, releaseYear, djComment
        FROM content WHERE content_id = 1
        """, columns: 16).first)
    #expect(alpha == [
        .text("Alpha"), .int(12_450), .int(200), .int(3), .text("/Contents/Ann/First/alpha.mp3"), .text("alpha.mp3"),
        .int(5_000), .int(1), .int(320), .int(44_100), .text("/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT"), .int(1),
        .int(777), .int(1), .int(2020), .text("hi")])
    // A track with no analysis files has hot-cue auto-load off, as in export.pdb.
    let beta = try database.rows("SELECT isHotCueAutoLoadOn, fileType FROM content WHERE content_id = 2", columns: 2).first
    #expect(beta == [.int(0), .int(11)])

    // Lookups share export.pdb's ids and are deduplicated.
    #expect(try database.rows("SELECT COUNT(*) FROM artist", columns: 1).first?.first == .int(1))
    let ids = try database.rows("SELECT artist_id_artist, album_id, genre_id, label_id FROM content ORDER BY content_id", columns: 4)
    #expect(ids == [[.int(1), .int(1), .int(1), .int(1)], [.int(1), .int(1), .int(1), .int(0)]])
}

@Test func cuesUseTheReferenceKindsAndUnits() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)
    let rows = try open(url).rows(
        "SELECT kind, colorTableIndex, cueComment, inUsec, outUsec, in150FramePerSec, out150FramePerSec FROM cue ORDER BY kind, inUsec",
        columns: 7)
    // Memory loop (kind 0), hot cue A (1) and hot cue D, which skips the reserved kind 4 (5).
    #expect(rows.map { $0[0] } == [.int(0), .int(1), .int(5)])
    #expect(rows[0][3...] == [.int(4_000_000), .int(6_000_000), .int(600), .int(900)])
    #expect(rows[1][3...] == [.int(1_000_000), .int(-1), .int(150), .int(-1)])
    #expect(rows[2][2] == .text("D"))
    #expect(rows[1][1] == .int(Int64(RekordboxCuePalette.nearest(to: .init(red: 0xFF, green: 0, blue: 0)).code)))
}

@Test func playlistsKeepFoldersParentsAndOneBasedOrder() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)
    let database = try open(url)
    let nodes = try database.rows(
        "SELECT playlist_id, sequenceNo, name, attribute, playlist_id_parent FROM playlist ORDER BY playlist_id", columns: 5)
    #expect(nodes == [
        [.int(1), .int(0), .text("Folder"), .int(1), .int(0)],
        [.int(2), .int(0), .text("Set"), .int(0), .int(1)]
    ])
    let entries = try database.rows(
        "SELECT content_id, sequenceNo FROM playlist_content WHERE playlist_id = 2 ORDER BY sequenceNo", columns: 2)
    #expect(entries == [[.int(2), .int(1)], [.int(1), .int(2)]])
}

@Test func existingBrowseSettingsSurviveARebuild() throws {
    let first = scratchDatabase()
    let second = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

    var custom = OneLibrarySettings.defaults
    custom.colors[0].name = "Hot Pink"
    custom.backgroundColorType = 5
    custom.categories[0].visible = true  // GENRE on
    custom.categories.append(.init(id: 99, menuItem: 9_999, sequence: 0, visible: true))  // names no known menu item
    try write(first, settings: custom)

    let read = try #require(OneLibrarySettings.read(from: first))
    #expect(read.colors.first?.name == "Hot Pink")
    #expect(read.backgroundColorType == 5)
    #expect(read.categories.first { $0.id == 1 }?.visible == true)
    #expect(read.categories.contains { $0.id == 99 } == false)  // dropped on the way in

    try write(second, settings: read)
    #expect(try open(second).rows("SELECT name FROM color WHERE color_id = 1", columns: 1).first?.first == .text("Hot Pink"))
    #expect(try open(second).rows("SELECT backGroundColorType FROM property", columns: 1).first?.first == .int(5))
    #expect(OneLibrarySettings.read(from: URL(fileURLWithPath: "/nonexistent/db")) == nil)
}

// MARK: - Export integration

private func environment() -> CDJExportEnvironment {
    CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in .max })
}

private func makeStick() throws -> (directory: URL, stick: URL, track: Track, crate: Crate) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("onelibexp-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("one.mp3")
    try Data("audio".utf8).write(to: file)
    let track = Track(seratoStoredPath: "p/one.mp3", fileURL: file, title: "One", artist: "A", album: "B", duration: 3)
    return (directory, stick, track, Crate(pathComponents: ["Set"], trackPaths: [track.seratoStoredPath]))
}

@Test func exportWritesAnEncryptedLibraryAndKeepsItsSettingsNextTime() async throws {
    let (directory, stick, track, crate) = try makeStick()
    defer { try? FileManager.default.removeItem(at: directory) }
    func plan() -> CDJExportPlan {
        CDJSeratoExport.plan(crates: [crate], library: [track], previous: CDJExportManifest.load(from: stick, root: "PIONEER"))
    }
    _ = try await CDJSeratoExport.export(plan(), to: stick, environment: environment())
    let library = stick.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")
    #expect(try open(library).rows("SELECT COUNT(*) FROM content", columns: 1).first?.first == .int(1))
    #expect(try open(library).rows("SELECT deviceName FROM property", columns: 1).first?.first == .text("STICK"))

    // The DJ renames a colour on the stick; the next export keeps it.
    let edited = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: edited) }
    var custom = try #require(OneLibrarySettings.read(from: library))
    custom.colors[1].name = "Crimson"
    try OneLibraryWriter.write(
        to: edited, tracks: [], playlists: [], analyses: [:], deviceName: "STICK", createdDate: "2026-01-01",
        libraryID: 1, settings: custom)
    try FileManager.default.removeItem(at: library)
    try FileManager.default.copyItem(at: edited, to: library)

    // A stale journal from rekordbox is cleared when the database is rebuilt.
    try Data("stale".utf8).write(to: URL(fileURLWithPath: library.path + "-wal"))
    try Data("stale".utf8).write(to: URL(fileURLWithPath: library.path + "-shm"))

    // The track is untouched, so only the databases are rewritten.
    let second = try await CDJSeratoExport.export(plan(), to: stick, environment: environment())
    #expect(second.filesCopied == 0)
    #expect(try open(library).rows("SELECT name FROM color WHERE color_id = 2", columns: 1).first?.first == .text("Crimson"))
    #expect(try open(library).rows("SELECT COUNT(*) FROM content", columns: 1).first?.first == .int(1))
    #expect(!FileManager.default.fileExists(atPath: library.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: library.path + "-shm"))
}

@Test func aLibraryThisAppDidNotWriteIsNotReplacedWithoutAsking() async throws {
    let (directory, stick, track, crate) = try makeStick()
    defer { try? FileManager.default.removeItem(at: directory) }
    let theirs = stick.appendingPathComponent("PIONEER/rekordbox/export.pdb")
    try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("rekordbox library".utf8).write(to: theirs)

    let state = try CDJSeratoExport.stickState(at: stick)
    #expect(state.foreignLibrary)
    let plan = CDJSeratoExport.plan(crates: [crate], library: [track], previous: state.manifest, root: state.root)
    await #expect(throws: CDJExportError.self) {
        try await CDJSeratoExport.export(plan, to: stick, environment: environment())
    }
    #expect(try Data(contentsOf: theirs) == Data("rekordbox library".utf8))  // untouched

    let allowed = CDJSeratoExport.plan(
        crates: [crate], library: [track], previous: state.manifest, root: state.root,
        options: CDJExportOptions(replaceForeignLibrary: true))
    _ = try await CDJSeratoExport.export(allowed, to: stick, environment: environment())
    #expect(try Data(contentsOf: theirs) != Data("rekordbox library".utf8))
    #expect(try CDJSeratoExport.stickState(at: stick).foreignLibrary == false)  // ours now
}

@Test func verifierRejectsALibraryThatDisagreesWithTheExport() throws {
    let url = scratchDatabase()
    defer { try? FileManager.default.removeItem(at: url) }
    try write(url)
    let plan = CDJSeratoExport.plan(crates: [], library: [])
    var mismatched = plan
    mismatched.playlists = []  // the plan has no playlists but the database has two
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verifyOneLibrary(at: url, plan: mismatched, tracks: sampleTracks())
    }
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verifyOneLibrary(at: url, plan: plan, tracks: [])  // wrong track count
    }
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verifyOneLibrary(
            at: URL(fileURLWithPath: "/nonexistent/db"), plan: plan, tracks: sampleTracks())
    }
}
