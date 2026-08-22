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

private func track(_ path: String, title: String = "", artist: String = "") -> SnapshotTrack {
    SnapshotTrack(storedPath: path, title: title, artist: artist)
}

private func makeLibrary() -> SnapshotLibrary {
    let snapshot = LibrarySnapshot(
        libraryFingerprint: "test",
        tracks: [
            track("Music/intro.mp3", title: "Intro", artist: "Nova"),
            track("Music/banger.mp3", title: "Banger", artist: "Nova"),
            track("Music/outro.mp3", title: "Outro", artist: "Vega"),
            track("Music/unfiled.mp3", title: "Unfiled", artist: "Vega")
        ],
        crates: [
            SnapshotCrate(pathComponents: ["Sets"], trackPaths: ["Music/intro.mp3"]),
            SnapshotCrate(pathComponents: ["Sets", "Peak"], trackPaths: ["Music/banger.mp3"]),
            SnapshotCrate(pathComponents: ["Sets", "Close"], trackPaths: ["Music/outro.mp3"])
        ]
    )
    return SnapshotLibrary(snapshot: snapshot)
}

@Test func libraryExposesCountsAndTheCrateTree() {
    let library = makeLibrary()
    #expect(library.trackCount == 4)
    #expect(library.crateCount == 3)
    #expect(library.crateTree.map(\.name) == ["Sets"])
    #expect(library.crateTree[0].children.map(\.name) == ["Close", "Peak"])
}

@Test func tracksInACrateFollowTheCrateOrder() {
    let library = makeLibrary()
    let peak = library.crateTree[0].children.first { $0.name == "Peak" }!
    #expect(library.tracks(in: peak).map(\.title) == ["Banger"])
}

@Test func tracksInANodeIncludeTheWholeSubtree() {
    let library = makeLibrary()
    #expect(library.tracks(in: library.crateTree[0]).map(\.title) == ["Intro", "Outro", "Banger"])
}

@Test func lookupByStoredPathFindsTheTrack() {
    let library = makeLibrary()
    #expect(library.track(for: "Music/outro.mp3")?.title == "Outro")
    #expect(library.track(for: "Music/nope.mp3") == nil)
}

/// A crate listing a path the snapshot has no track for is skipped, not
/// filled with a placeholder — a fake row would hide the inconsistency.
@Test func crateEntriesWithNoMatchingTrackAreSkipped() {
    let snapshot = LibrarySnapshot(
        libraryFingerprint: "test",
        tracks: [track("Music/real.mp3", title: "Real")],
        crates: [SnapshotCrate(pathComponents: ["Set"], trackPaths: ["Music/real.mp3", "Music/ghost.mp3"])]
    )
    let library = SnapshotLibrary(snapshot: snapshot)
    #expect(library.tracks(in: snapshot.crates[0]).map(\.title) == ["Real"])
}

@Test func tracksNotInAnyCrateFindsTheUnfiledOnes() {
    #expect(makeLibrary().tracksNotInAnyCrate.map(\.title) == ["Unfiled"])
}

@Test func searchUsesThePrebuiltIndexAndMatchesTheSameFields() {
    let library = makeLibrary()
    #expect(library.search("nova").map(\.title) == ["Intro", "Banger"])
    #expect(library.search("VEGA").map(\.title) == ["Outro", "Unfiled"])
    #expect(library.search("").count == 4)
}

/// Search must reach the file name too — DJs name files things the tags
/// don't say.
@Test func searchCoversTheFileName() {
    let snapshot = LibrarySnapshot(
        libraryFingerprint: "test",
        tracks: [track("Music/secret-bootleg.mp3", title: "Untitled")],
        crates: []
    )
    #expect(SnapshotLibrary(snapshot: snapshot).search("bootleg").count == 1)
}

@Test func scopedSearchOnlyLooksInsideThatCrate() {
    let library = makeLibrary()
    let peak = library.crateTree[0].children.first { $0.name == "Peak" }!
    #expect(library.search("nova", in: peak).map(\.title) == ["Banger"])
    #expect(library.search("vega", in: peak).isEmpty)
}

// MARK: - Folder discovery

private func makeSnapshotFolder() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func folderListsSnapshotsNewestFirstAndIgnoresOtherFiles() throws {
    let directory = try makeSnapshotFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    for (index, name) in ["snapshot-a.json", "snapshot-b.json"].enumerated() {
        let url = directory.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index) * 60)],
            ofItemAtPath: url.path
        )
    }
    try Data("{}".utf8).write(to: directory.appendingPathComponent("queue-x.json"))
    try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))

    let found = SnapshotFolder.snapshots(in: directory)
    #expect(found.map(\.lastPathComponent) == ["snapshot-b.json", "snapshot-a.json"])
}

@Test func loadingTheNewestSnapshotReturnsABrowsableLibrary() throws {
    let directory = try makeSnapshotFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let older = LibrarySnapshot(libraryFingerprint: "old", tracks: [track("a.mp3", title: "Old")], crates: [])
    let newer = LibrarySnapshot(libraryFingerprint: "new", tracks: [track("b.mp3", title: "New")], crates: [])

    let olderURL = directory.appendingPathComponent(LibrarySnapshotBuilder.fileName(for: older))
    try LibrarySnapshotBuilder.encode(older).write(to: olderURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: olderURL.path)

    let newerURL = directory.appendingPathComponent(LibrarySnapshotBuilder.fileName(for: newer))
    try LibrarySnapshotBuilder.encode(newer).write(to: newerURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 9_000)], ofItemAtPath: newerURL.path)

    #expect(try SnapshotFolder.loadNewest(in: directory).allTracks.map(\.title) == ["New"])
}

@Test func anEmptyFolderExplainsHowToFixIt() throws {
    let directory = try makeSnapshotFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let error = #expect(throws: SnapshotFolder.FolderError.self) {
        try SnapshotFolder.loadNewest(in: directory)
    }
    #expect(error?.errorDescription?.isEmpty == false)
    #expect(error?.recoverySuggestion?.contains("Export Snapshot") == true)
}
