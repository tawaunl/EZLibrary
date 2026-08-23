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
@testable import EZLibraryCore

@Suite(.serialized)
struct TrackBulkRenameServiceTests {

private struct Env {
    let root: URL
    let libraryDirectory: URL
    let musicDirectory: URL
    let databaseFileURL: URL
    let crateURL: URL
    let smartCrateURL: URL
}

/// A small library: a `database V2`, one plain crate and one smart crate
/// carrying rule chunks, all naming the same tracks.
private func makeLibrary(_ specs: [(name: String, artist: String, title: String)]) throws -> Env {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bulk-rename-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    let musicDirectory = root.appendingPathComponent("Music", isDirectory: true)
    for directory in [
        libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true),
        libraryDirectory.appendingPathComponent("SmartCrates", isDirectory: true),
        musicDirectory
    ] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    TestBackupDirectory.use()

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: root)
    var databaseData = Data()
    var storedPaths: [String] = []
    for spec in specs {
        let url = musicDirectory.appendingPathComponent(spec.name)
        try Data("audio".utf8).write(to: url)
        let stored = SeratoLibraryLocator.seratoStoredPath(for: url, rootDirectory: rootDirectory)
        storedPaths.append(stored)
        databaseData = SeratoDatabaseWriter.ensuringTrackExists(
            forStoredPath: stored,
            metadata: SeratoTrackMetadataUpdate(
                title: spec.title, artist: spec.artist, album: "", genre: "",
                comment: "", key: "", bpm: nil, year: nil),
            in: databaseData
        ).data
    }
    let databaseFileURL = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
    try databaseData.write(to: databaseFileURL)

    let crateURL = libraryDirectory.appendingPathComponent("Subcrates/Party.crate")
    try SeratoCrateWriter.makeCrateData(trackPaths: storedPaths).write(to: crateURL)

    // Smart crates keep a materialized member list beside their rules; the
    // rule chunk is here so the test can prove it survives the rewrite.
    let smartCrateURL = libraryDirectory.appendingPathComponent("SmartCrates/Auto.scrate")
    var smartChunks: [SeratoChunk] = [
        SeratoChunk(tag: "vrsn", payload: SeratoChunkCodec.encodeUTF16BEString("1.0/Serato ScratchLive Crate")),
        SeratoChunk(tag: "rurt", payload: Data([0x00, 0x01, 0x02, 0x03]))
    ]
    for stored in storedPaths {
        smartChunks.append(
            SeratoChunk(
                tag: "otrk",
                payload: SeratoChunkCodec.writeChunk(
                    SeratoChunk(tag: "ptrk", payload: SeratoChunkCodec.encodeUTF16BEString(stored)))))
    }
    try SeratoChunkCodec.writeChunks(smartChunks).write(to: smartCrateURL)

    return Env(
        root: root,
        libraryDirectory: libraryDirectory,
        musicDirectory: musicDirectory,
        databaseFileURL: databaseFileURL,
        crateURL: crateURL,
        smartCrateURL: smartCrateURL
    )
}

private func tracks(in env: Env) throws -> [Track] {
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.root)
    return try SeratoDatabaseParser.parseTracks(at: env.databaseFileURL, rootDirectory: rootDirectory)
}

// MARK: - Tests

@Test func renamesEveryTrackAndUpdatesDatabaseAndBothCrateKinds() throws {
    let env = try makeLibrary([
        (name: "one.mp3", artist: "Disclosure", title: "Latch"),
        (name: "two.mp3", artist: "Caribou", title: "Odessa")
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let preview = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)
    #expect(preview.renames.count == 2)
    #expect(preview.skips.isEmpty)

    let result = try TrackBulkRenameService.apply(preview)
    #expect(result.renamedCount == 2)

    let names = try FileManager.default.contentsOfDirectory(atPath: env.musicDirectory.path).sorted()
    #expect(names == ["Caribou-Odessa.mp3", "Disclosure-Latch.mp3"])

    let stored = Set(SeratoDatabaseParser.storedPaths(from: try Data(contentsOf: env.databaseFileURL)))
    #expect(stored.contains { $0.hasSuffix("Disclosure-Latch.mp3") })
    #expect(!stored.contains { $0.hasSuffix("one.mp3") })

    let cratePaths = SeratoCrateParser.trackPaths(from: try Data(contentsOf: env.crateURL))
    #expect(cratePaths.allSatisfy { !$0.hasSuffix("one.mp3") && !$0.hasSuffix("two.mp3") })

    // Smart crate is rewritten too, and keeps its rule chunk.
    let smartData = try Data(contentsOf: env.smartCrateURL)
    #expect(SeratoCrateParser.trackPaths(from: smartData).allSatisfy { $0.hasSuffix("-Latch.mp3") || $0.hasSuffix("-Odessa.mp3") })
    #expect(SeratoChunkCodec.readChunks(from: smartData).contains { $0.tag == "rurt" })
}

@Test func skipsTracksThatWouldCollideWithEachOther() throws {
    // Same artist and title, different files: the template can't tell them
    // apart, so neither is renamed.
    let env = try makeLibrary([
        (name: "a.mp3", artist: "Aphex Twin", title: "Xtal"),
        (name: "b.mp3", artist: "Aphex Twin", title: "Xtal"),
        (name: "c.mp3", artist: "Boards", title: "Roygbiv")
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let preview = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)

    #expect(preview.renames.count == 1)
    #expect(preview.skips.count == 2)
    #expect(preview.skips.allSatisfy { $0.reason == .collidesWithAnotherRename })

    _ = try TrackBulkRenameService.apply(preview)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: env.musicDirectory.path))
    #expect(names.contains("a.mp3"))
    #expect(names.contains("b.mp3"))
    #expect(names.contains("Boards-Roygbiv.mp3"))
}

@Test func skipsTracksAlreadyNamedCorrectly() throws {
    let env = try makeLibrary([(name: "Disclosure-Latch.mp3", artist: "Disclosure", title: "Latch")])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let preview = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)

    #expect(preview.isEmpty)
    #expect(preview.skips.map(\.reason) == [.alreadyNamedCorrectly])
}

@Test func skipsTracksWithNothingToRenderAndDestinationsAlreadyTaken() throws {
    let env = try makeLibrary([
        (name: "blank.mp3", artist: "", title: ""),
        (name: "taken.mp3", artist: "Occupied", title: "Name")
    ])
    defer { try? FileManager.default.removeItem(at: env.root) }

    // Something unrelated already occupies the destination.
    try Data("other".utf8).write(to: env.musicDirectory.appendingPathComponent("Occupied-Name.mp3"))

    let preview = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)

    #expect(preview.isEmpty)
    #expect(Set(preview.skips.map(\.reason)) == [.noNameFromTemplate, .destinationExists])
}

@Test func refusesToRunWhileSeratoIsRunning() throws {
    let env = try makeLibrary([(name: "one.mp3", artist: "Disclosure", title: "Latch")])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let preview = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)

    TestSeratoEnvironment.withSeratoRunning {
        #expect(throws: TrackBulkRenameService.RenameError.self) {
            try TrackBulkRenameService.apply(preview)
        }
    }
    #expect(FileManager.default.fileExists(atPath: env.musicDirectory.appendingPathComponent("one.mp3").path))
}

@Test func previewDoesNotTouchAnything() throws {
    let env = try makeLibrary([(name: "one.mp3", artist: "Disclosure", title: "Latch")])
    defer { try? FileManager.default.removeItem(at: env.root) }

    let before = try Data(contentsOf: env.databaseFileURL)
    _ = try TrackBulkRenameService.preview(
        tracks: try tracks(in: env), template: "{artist}-{title}", databaseFileURL: env.databaseFileURL)

    #expect(try Data(contentsOf: env.databaseFileURL) == before)
    #expect(FileManager.default.fileExists(atPath: env.musicDirectory.appendingPathComponent("one.mp3").path))
}

}
