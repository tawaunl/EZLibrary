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

/// A scratch library plus an empty folder standing in for a USB stick.
private struct Bench {
    let directory: URL
    let stick: URL
    var tracks: [Track] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjbench-\(UUID().uuidString)")
        stick = directory.appendingPathComponent("STICK")
        try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    }

    mutating func addTrack(_ name: String, artist: String = "Artist") throws -> Track {
        let url = directory.appendingPathComponent("\(name).mp3")
        try Data("audio-\(name)".utf8).write(to: url)
        let track = Track(
            seratoStoredPath: "lib/\(name).mp3", fileURL: url, title: name, artist: artist, album: "Album", duration: 5)
        tracks.append(track)
        return track
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    static let environment = CDJExportEnvironment(
        requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in Int.max })

    func plan(_ crates: [Crate]) -> CDJExportPlan {
        let manifest = CDJExportManifest.load(from: stick, root: "PIONEER")
        return CDJSeratoExport.plan(crates: crates, library: tracks, previous: manifest, root: "PIONEER")
    }

    func run(_ crates: [Crate]) async throws -> CDJExportResult {
        try await CDJSeratoExport.export(plan(crates), to: stick, environment: Self.environment)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: stick.appendingPathComponent(relative).path)
    }
}

@Test func firstExportWritesAVerifiedStick() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let two = try bench.addTrack("two")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath, two.seratoStoredPath])

    let result = try await bench.run([crate])
    #expect(result.tracksWritten == 2)
    #expect(result.filesCopied == 2)
    #expect(result.playlistCount == 1)

    let plan = bench.plan([crate])
    for item in plan.items {
        #expect(bench.exists(String(item.export.stickPath.dropFirst())))
        #expect(bench.exists(String(item.export.analyzePath.dropFirst())))
        #expect(bench.exists(String(item.export.analyzePath.dropFirst().dropLast(3)) + "EXT"))
        #expect(bench.exists(String(item.export.analyzePath.dropFirst().dropLast(3)) + "2EX"))
    }
    let database = try Data(contentsOf: bench.stick.appendingPathComponent("PIONEER/rekordbox/export.pdb"))
    let file = try RekordboxPDBFile(database)
    #expect(try file.rowOffsets(inTable: 0).count == 2)
    #expect(bench.exists("PIONEER/CDJSeratoExport/manifest.json"))
    #expect(!bench.exists(CDJExportPublication.directoryName))
}

@Test func laterExportsReuseFilesAndKeepTrackIDs() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let two = try bench.addTrack("two")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath, two.seratoStoredPath])
    _ = try await bench.run([crate])
    let firstIDs = bench.plan([crate]).items.map { $0.export.id }

    // A new track in front must not renumber the others.
    let zero = try bench.addTrack("zero")
    let bigger = Crate(
        pathComponents: ["Set"], trackPaths: [zero.seratoStoredPath, one.seratoStoredPath, two.seratoStoredPath])
    let result = try await bench.run([bigger])
    #expect(result.filesCopied == 1)
    #expect(result.filesAlreadyOnStick == 2)

    let after = bench.plan([bigger]).items
    func id(_ key: String) -> UInt32? { after.first { $0.key == key }?.export.id }
    #expect([id(one.seratoStoredPath), id(two.seratoStoredPath)] == firstIDs.map { Optional($0) })
    #expect(id(zero.seratoStoredPath) == 3)
}

@Test func changedSourceIsCopiedAgain() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])
    _ = try await bench.run([crate])

    try Data("audio-one-edited-and-longer".utf8).write(to: one.fileURL)
    bench.tracks[0] = one
    let result = try await bench.run([crate])
    #expect(result.filesCopied == 1)
    #expect(result.filesAlreadyOnStick == 0)
}

@Test func untickedCratesAreRemovedFromTheStick() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one", artist: "Keep")
    let two = try bench.addTrack("two", artist: "Drop")
    let keep = Crate(pathComponents: ["Keep"], trackPaths: [one.seratoStoredPath])
    let drop = Crate(pathComponents: ["Drop"], trackPaths: [two.seratoStoredPath])
    _ = try await bench.run([keep, drop])
    let droppedItem = bench.plan([keep, drop]).items.first { $0.key == two.seratoStoredPath }!
    let keptID = bench.plan([keep, drop]).items.first { $0.key == one.seratoStoredPath }!.export.id

    let plan = bench.plan([keep])
    #expect(plan.removals.count == 1)
    let result = try await bench.run([keep])
    #expect(result.tracksRemoved == 1)
    #expect(!bench.exists(String(droppedItem.export.stickPath.dropFirst())))
    #expect(!bench.exists(String(droppedItem.export.analyzePath.dropFirst())))
    #expect(!bench.exists("Contents/Drop"))  // the emptied folder goes too
    #expect(bench.exists("Contents/Keep"))
    #expect(bench.plan([keep]).items.first?.export.id == keptID)

    // Bringing it back gets a fresh id: ids of removed tracks are never reused.
    _ = try await bench.run([keep, drop])
    let again = bench.plan([keep, drop]).items.first { $0.key == two.seratoStoredPath }!.export.id
    #expect(again != droppedItem.export.id)
}

@Test func exportRefusesAStickThatChangedAfterPlanning() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])
    let stale = bench.plan([crate])  // planned against a blank stick
    _ = try await bench.run([crate])  // ...which then got an export from elsewhere
    await #expect(throws: CDJExportError.self) {
        try await CDJSeratoExport.export(stale, to: bench.stick, environment: Bench.environment)
    }
}

@Test func failedExportLeavesTheStickUntouched() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])
    var plan = bench.plan([crate])
    try FileManager.default.removeItem(at: one.fileURL)  // the file vanishes before it can be copied
    plan.items = plan.items.map { $0 }
    await #expect(throws: (any Error).self) {
        try await CDJSeratoExport.export(plan, to: bench.stick, environment: Bench.environment)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bench.stick.path).isEmpty)
}

@Test func unusableFormatsAreRefusedBeforeAnythingIsWritten() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let plan = bench.plan([Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])])
    let ntfs = CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .ntfs }, freeBytes: { _ in .max })
    await #expect(throws: CDJExportError.self) {
        try await CDJSeratoExport.export(plan, to: bench.stick, environment: ntfs)
    }
    let tight = CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in 10 })
    await #expect(throws: CDJExportError.self) {
        try await CDJSeratoExport.export(plan, to: bench.stick, environment: tight)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bench.stick.path).isEmpty)
}

// MARK: - Publication journal

private func makeVolume() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cdjpub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func put(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

@Test func interruptedPublicationIsUndoneByTheNextRun() throws {
    let volume = try makeVolume()
    defer { try? FileManager.default.removeItem(at: volume) }
    let publication = CDJExportPublication(volume: volume)
    try put("old-a", at: volume.appendingPathComponent("a.txt"))
    try put("old-c", at: volume.appendingPathComponent("c.txt"))
    try publication.prepare()
    try put("new-a", at: publication.stagedURL("a.txt"))
    try put("new-b", at: publication.stagedURL("sub/b.txt"))

    // The "crash": commit runs, finish never does.
    try publication.commit(.init(placements: ["a.txt", "sub/b.txt"], removals: ["c.txt"]))
    #expect(read(volume.appendingPathComponent("a.txt")) == "new-a")
    #expect(read(volume.appendingPathComponent("c.txt")) == nil)

    let recovered = try CDJExportPublication(volume: volume).recoverInterruptedPublication()
    #expect(recovered)
    #expect(read(volume.appendingPathComponent("a.txt")) == "old-a")
    #expect(read(volume.appendingPathComponent("c.txt")) == "old-c")
    #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent("sub/b.txt").path))
    #expect(!FileManager.default.fileExists(atPath: publication.directory.path))
}

@Test func failedCommitRestoresWhatItAlreadyMoved() throws {
    let volume = try makeVolume()
    defer { try? FileManager.default.removeItem(at: volume) }
    let publication = CDJExportPublication(volume: volume)
    try put("old-a", at: volume.appendingPathComponent("a.txt"))
    try publication.prepare()
    try put("new-a", at: publication.stagedURL("a.txt"))
    // "missing.txt" was never staged, so the second move fails.
    #expect(throws: (any Error).self) {
        try publication.commit(.init(placements: ["a.txt", "missing.txt"], removals: []))
    }
    #expect(read(volume.appendingPathComponent("a.txt")) == "old-a")
}

@Test func recoveryWithoutAJournalJustClearsTheStage() throws {
    let volume = try makeVolume()
    defer { try? FileManager.default.removeItem(at: volume) }
    let publication = CDJExportPublication(volume: volume)
    try publication.prepare()
    try put("x", at: publication.stagedURL("x.txt"))
    #expect(try publication.recoverInterruptedPublication() == false)
    #expect(!FileManager.default.fileExists(atPath: publication.directory.path))
}

// MARK: - Root selection and verification

@Test func rootSelectionKeepsWhateverTheStickAlreadyUses() throws {
    let volume = try makeVolume()
    defer { try? FileManager.default.removeItem(at: volume) }
    #expect(try CDJExportRoot.select(on: volume, format: .fat32) == "PIONEER")
    #expect(try CDJExportRoot.select(on: volume, format: .hfsPlus) == ".PIONEER")

    try put("x", at: volume.appendingPathComponent(".PIONEER/rekordbox/export.pdb"))
    #expect(try CDJExportRoot.select(on: volume, format: .fat32) == ".PIONEER")

    try put("x", at: volume.appendingPathComponent("PIONEER/DEVSETTING.DAT"))
    #expect(throws: CDJExportError.self) { try CDJExportRoot.select(on: volume, format: .fat32) }
}

@Test func verifierAcceptsTheWritersOutputAndRejectsDamage() throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let plan = bench.plan([Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])])
    let database = RekordboxPDBWriter.build(tracks: plan.items.map(\.export), playlists: plan.playlists)
    let item = plan.items[0]
    let dat = RekordboxAnalysisWriter.datFile(CDJAnalysisInput(stickPath: item.export.stickPath, durationMs: 1000))

    try RekordboxExportVerifier.verify(database: database, plan: plan, analysis: { _ in dat }, fileExists: { _ in true })

    // Audio the database names but the stick doesn't have.
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verify(database: database, plan: plan, analysis: { _ in dat }, fileExists: { _ in false })
    }
    // A table that no longer starts with an index page: rekordbox calls such a file corrupt.
    var damaged = database
    let tracks = try #require(try RekordboxPDBFile(database).table(0))
    damaged[tracks.first * 4096 + 0x1b] = 0x24
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verify(database: damaged, plan: plan, analysis: { _ in dat }, fileExists: { _ in true })
    }
    // An analysis file whose path names some other audio file.
    let wrong = RekordboxAnalysisWriter.datFile(CDJAnalysisInput(stickPath: "/Contents/Other.mp3", durationMs: 1000))
    #expect(throws: CDJExportError.self) {
        try RekordboxExportVerifier.verify(database: database, plan: plan, analysis: { _ in wrong }, fileExists: { _ in true })
    }
}

@Test func aStickMissingItsThreeBandFileGetsItOnTheNextExport() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one")
    let crate = Crate(pathComponents: ["Set"], trackPaths: [one.seratoStoredPath])
    _ = try await bench.run([crate])
    let item = bench.plan([crate]).items[0]
    let twoEx = bench.stick.appendingPathComponent(String(item.export.analyzePath.dropFirst().dropLast(3)) + "2EX")
    try FileManager.default.removeItem(at: twoEx)

    let result = try await bench.run([crate])
    #expect(result.filesCopied == 0)  // the audio is untouched...
    #expect(FileManager.default.fileExists(atPath: twoEx.path))  // ...but the analysis is repaired
}

@Test func removedTracksTakeTheirThreeAnalysisFilesWithThem() async throws {
    var bench = try Bench()
    defer { bench.cleanUp() }
    let one = try bench.addTrack("one", artist: "Keep")
    let two = try bench.addTrack("two", artist: "Drop")
    let keep = Crate(pathComponents: ["Keep"], trackPaths: [one.seratoStoredPath])
    let drop = Crate(pathComponents: ["Drop"], trackPaths: [two.seratoStoredPath])
    _ = try await bench.run([keep, drop])
    let dropped = bench.plan([keep, drop]).items.first { $0.key == two.seratoStoredPath }!
    let base = String(dropped.export.analyzePath.dropFirst().dropLast(3))
    #expect(bench.exists(base + "2EX"))

    _ = try await bench.run([keep])
    for ext in ["DAT", "EXT", "2EX"] { #expect(!bench.exists(base + ext)) }
}
