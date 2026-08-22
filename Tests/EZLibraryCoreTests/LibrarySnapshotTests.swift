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

private func realLibraryDirectory() -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
}

private func sampleTrack() -> Track {
    Track(
        seratoStoredPath: "Users/dj/Music/All Music/Midnight Drive.mp3",
        fileURL: URL(fileURLWithPath: "/Users/dj/Music/All Music/Midnight Drive.mp3"),
        title: "Midnight Drive",
        artist: "Nova",
        album: "Neon Nights",
        genre: "House",
        comment: "intro edit",
        grouping: "warmup",
        label: "Neon Records",
        year: 2026,
        duration: 372.5,
        bpm: 124.5,
        key: "8A",
        trackNumber: 3,
        dateAdded: Date(timeIntervalSince1970: 1_750_000_000),
        playCount: 12
    )
}

@Test func snapshotTrackCarriesEveryEditableField() {
    let snapshot = SnapshotTrack(track: sampleTrack())
    #expect(snapshot.storedPath == "Users/dj/Music/All Music/Midnight Drive.mp3")
    #expect(snapshot.value(for: .title) == "Midnight Drive")
    #expect(snapshot.value(for: .artist) == "Nova")
    #expect(snapshot.value(for: .album) == "Neon Nights")
    #expect(snapshot.value(for: .genre) == "House")
    #expect(snapshot.value(for: .comment) == "intro edit")
    #expect(snapshot.value(for: .key) == "8A")
    #expect(snapshot.value(for: .year) == "2026")
    #expect(snapshot.value(for: .bpm) == "124.5")
}

@Test func unsetFieldsReadAsNilRatherThanEmptyStrings() {
    let track = Track(seratoStoredPath: "a.mp3", fileURL: URL(fileURLWithPath: "/a.mp3"))
    let snapshot = SnapshotTrack(track: track)
    for field in TrackField.allCases {
        #expect(snapshot.value(for: field) == nil)
    }
}

/// The editable set is pinned to what `SeratoTrackMetadataUpdate` can write —
/// `grouping`, `label`, and `trackNumber` have no write path, so no remote
/// device may offer an edit for them.
@Test func editableFieldsMatchWhatTheMetadataWriterSupports() {
    #expect(Set(TrackField.allCases.map(\.rawValue)) == ["title", "artist", "album", "genre", "comment", "key", "bpm", "year"])
}

@Test func snapshotSurvivesAnEncodeDecodeRoundTrip() throws {
    let original = LibrarySnapshot(
        libraryFingerprint: "abc123",
        tracks: [SnapshotTrack(track: sampleTrack())],
        crates: [SnapshotCrate(pathComponents: ["ALL GENRES", "Disco"], trackPaths: ["a.mp3", "b.mp3"])]
    )
    let decoded = try LibrarySnapshotBuilder.decode(try LibrarySnapshotBuilder.encode(original))
    #expect(decoded == original)
    #expect(decoded.crates[0].name == "Disco")
}

@Test func decodingRefusesASnapshotFromANewerVersion() throws {
    let future = LibrarySnapshot(
        schemaVersion: LibrarySnapshot.currentSchemaVersion + 1,
        libraryFingerprint: "f",
        tracks: [],
        crates: []
    )
    let data = try LibrarySnapshotBuilder.encode(future)
    #expect(throws: LibrarySnapshotBuilder.SnapshotError.newerSchema(found: LibrarySnapshot.currentSchemaVersion + 1)) {
        try LibrarySnapshotBuilder.decode(data)
    }
}

@Test func decodingGarbageReportsAReadableError() {
    let error = #expect(throws: LibrarySnapshotBuilder.SnapshotError.self) {
        try LibrarySnapshotBuilder.decode(Data("not json".utf8))
    }
    #expect(error?.errorDescription?.isEmpty == false)
    #expect(error?.recoverySuggestion?.isEmpty == false)
}

@Test func snapshotFileNameIsStampedWithTheFingerprint() {
    let snapshot = LibrarySnapshot(libraryFingerprint: "deadbeef", tracks: [], crates: [])
    #expect(LibrarySnapshotBuilder.fileName(for: snapshot) == "snapshot-deadbeef.json")
}

@Test func writingAndReadingASnapshotRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-snapshot-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let snapshot = LibrarySnapshot(
        libraryFingerprint: "cafe",
        tracks: [SnapshotTrack(track: sampleTrack())],
        crates: []
    )
    let url = try LibrarySnapshotBuilder.write(snapshot, toDirectory: directory)
    #expect(url.lastPathComponent == "snapshot-cafe.json")
    #expect(try LibrarySnapshotBuilder.read(contentsOf: url) == snapshot)
}

@Test func readingAMissingSnapshotReportsAReadableError() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-missing-\(UUID().uuidString).json")
    let error = #expect(throws: LibrarySnapshotBuilder.SnapshotError.self) {
        try LibrarySnapshotBuilder.read(contentsOf: url)
    }
    #expect(error?.errorDescription?.contains("snapshot-missing") == true)
}

// MARK: - Against the real library fixture

@Test func snapshotOfTheRealFixtureKeepsEveryTrackAndCrate() throws {
    let directory = realLibraryDirectory()
    let tracks = try SeratoDatabaseParser.parseTracks(
        at: SeratoLibraryLocator.databaseFile(in: directory),
        rootDirectory: SeratoLibraryLocator.rootDirectory(for: directory)
    )
    let crates = SeratoLibraryLocator.subcrateFiles(in: directory).compactMap { entry in
        try? SeratoCrateParser.parseCrate(at: entry.url)
    }

    let snapshot = LibrarySnapshotBuilder.makeSnapshot(
        tracks: tracks,
        crates: crates,
        libraryDirectory: directory
    )

    #expect(snapshot.tracks.count == tracks.count)
    #expect(snapshot.crates.count == crates.count)
    #expect(!snapshot.libraryFingerprint.isEmpty)

    // Stored paths must survive verbatim — they are the identity every later
    // stage keys on.
    let snapshotPaths: [String] = snapshot.tracks.map { $0.storedPath }
    let parsedPaths: [String] = tracks.map { $0.seratoStoredPath }
    #expect(snapshotPaths == parsedPaths)

    let decoded = try LibrarySnapshotBuilder.decode(try LibrarySnapshotBuilder.encode(snapshot))
    #expect(decoded == snapshot)
}

/// Every track in the fixture must resolve to itself against an unchanged
/// library — anything less means the resolver would manufacture conflicts.
@Test func everyRealFixtureTrackResolvesToItself() throws {
    let directory = realLibraryDirectory()
    let tracks = try SeratoDatabaseParser.parseTracks(
        at: SeratoLibraryLocator.databaseFile(in: directory),
        rootDirectory: SeratoLibraryLocator.rootDirectory(for: directory)
    )
    #expect(!tracks.isEmpty)

    let resolver = TrackIdentityResolver(currentTracks: tracks)
    for track in tracks {
        let reference = TrackReference(snapshotTrack: SnapshotTrack(track: track))
        let expected = TrackIdentityResolver.Resolution.resolved(
            storedPath: track.seratoStoredPath,
            via: .exactPath
        )
        #expect(resolver.resolve(reference) == expected)
    }
}
