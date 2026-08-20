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

private func fixture(_ path: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent(path)
}

private struct Scratch {
    let root: URL
    let libraryDirectory: URL
    let databaseFile: URL
    let crateFile: URL
    let journalURL: URL
}

private func makeScratch() throws -> Scratch {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-offline-sync-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    let subcrates = libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
    try FileManager.default.createDirectory(at: subcrates, withIntermediateDirectories: true)

    let databaseFile = libraryDirectory.appendingPathComponent("database V2")
    let crateFile = subcrates.appendingPathComponent("Mike's Party.crate")
    try FileManager.default.copyItem(at: fixture("database V2"), to: databaseFile)
    try FileManager.default.copyItem(at: fixture("Subcrates/Mike's Party.crate"), to: crateFile)

    return Scratch(
        root: root,
        libraryDirectory: libraryDirectory,
        databaseFile: databaseFile,
        crateFile: crateFile,
        journalURL: root.appendingPathComponent("change-journal.json")
    )
}

/// The scenario the whole design turns on: a snapshot is taken, consolidation
/// then moves every file, and work composed against the old snapshot still
/// lands on the right tracks — by exact journal lookup, not by guessing.
@Suite(.serialized)
struct OfflineSyncIntegrationTests {

@Test func workBasedOnAPreConsolidationSnapshotStillResolves() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }
    TestBackupDirectory.use()

    // Friday: snapshot the library as it stands.
    let originalTracks = try SeratoDatabaseParser.parseTracks(
        at: scratch.databaseFile, rootDirectory: scratch.root)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)
    let selectedTracks = originalTracks.filter { crate.trackPaths.contains($0.seratoStoredPath) }
    #expect(selectedTracks.count >= 2)

    for track in selectedTracks {
        try FileManager.default.createDirectory(
            at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: track.fileURL)
    }

    let snapshot = LibrarySnapshotBuilder.makeSnapshot(
        tracks: selectedTracks,
        crates: [crate],
        libraryDirectory: scratch.libraryDirectory
    )

    // Saturday: consolidate, which rewrites every one of those paths.
    let preview = LibraryConsolidationService.preview(
        tracks: selectedTracks,
        destinationFolderURL: scratch.root.appendingPathComponent("Consolidated", isDirectory: true),
        homeDirectory: scratch.root
    )
    let result = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.root,
        databaseFileURL: scratch.databaseFile,
        journalURL: scratch.journalURL
    )
    #expect(result.processedTrackCount == selectedTracks.count)

    // The consolidation must have left a record of what it did.
    let journal = LibraryChangeJournal.load(from: scratch.journalURL)
    #expect(journal.entries.count == selectedTracks.count)

    // Sunday: the queue composed from Friday's snapshot arrives. Every
    // reference must resolve exactly, via the journal, to where the file
    // actually lives now.
    let currentTracks = try SeratoDatabaseParser.parseTracks(
        at: scratch.databaseFile, rootDirectory: scratch.root)
    let resolver = TrackIdentityResolver(currentTracks: currentTracks, journal: journal)

    for snapshotTrack in snapshot.tracks {
        let expectedPath = journal.currentPath(for: snapshotTrack.storedPath)
        #expect(expectedPath != snapshotTrack.storedPath)

        let resolution = resolver.resolve(TrackReference(snapshotTrack: snapshotTrack))
        #expect(resolution == .resolved(storedPath: expectedPath, via: .journal))
        #expect(currentTracks.contains { $0.seratoStoredPath == expectedPath })
    }
}

/// Without the journal the same references still land, but only through the
/// approximate tiers — which is the difference the journal buys.
@Test func withoutAJournalTheSameWorkFallsBackToApproximateMatching() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }
    TestBackupDirectory.use()

    let originalTracks = try SeratoDatabaseParser.parseTracks(
        at: scratch.databaseFile, rootDirectory: scratch.root)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)
    let selectedTracks = originalTracks.filter { crate.trackPaths.contains($0.seratoStoredPath) }

    for track in selectedTracks {
        try FileManager.default.createDirectory(
            at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: track.fileURL)
    }

    let snapshot = LibrarySnapshotBuilder.makeSnapshot(
        tracks: selectedTracks, crates: [crate], libraryDirectory: scratch.libraryDirectory)

    let preview = LibraryConsolidationService.preview(
        tracks: selectedTracks,
        destinationFolderURL: scratch.root.appendingPathComponent("Consolidated", isDirectory: true),
        homeDirectory: scratch.root
    )
    _ = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.root,
        databaseFileURL: scratch.databaseFile,
        journalURL: nil
    )

    #expect(!FileManager.default.fileExists(atPath: scratch.journalURL.path))

    let currentTracks = try SeratoDatabaseParser.parseTracks(
        at: scratch.databaseFile, rootDirectory: scratch.root)
    let resolver = TrackIdentityResolver(currentTracks: currentTracks)

    for snapshotTrack in snapshot.tracks {
        let resolution = resolver.resolve(TrackReference(snapshotTrack: snapshotTrack))
        // Consolidation keeps filenames, so basename carries it — but this is
        // inference, and it is the tier that collides in a messier library.
        guard case let .resolved(_, tier) = resolution else {
            Issue.record("expected a resolution for \(snapshotTrack.storedPath)")
            continue
        }
        #expect(tier == .basename)
    }
}

/// A consolidation that fails to journal must still be a successful
/// consolidation — the files have already moved by then.
@Test func consolidationSucceedsEvenWhenTheJournalCannotBeWritten() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }
    TestBackupDirectory.use()

    let originalTracks = try SeratoDatabaseParser.parseTracks(
        at: scratch.databaseFile, rootDirectory: scratch.root)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)
    let selectedTracks = originalTracks.filter { crate.trackPaths.contains($0.seratoStoredPath) }

    for track in selectedTracks {
        try FileManager.default.createDirectory(
            at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: track.fileURL)
    }

    let preview = LibraryConsolidationService.preview(
        tracks: selectedTracks,
        destinationFolderURL: scratch.root.appendingPathComponent("Consolidated", isDirectory: true),
        homeDirectory: scratch.root
    )

    // A path that cannot be created: the parent is a regular file.
    let blocker = scratch.root.appendingPathComponent("blocked")
    try Data("x".utf8).write(to: blocker)
    let unwritable = blocker.appendingPathComponent("nested/change-journal.json")

    let result = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.root,
        databaseFileURL: scratch.databaseFile,
        journalURL: unwritable
    )

    #expect(result.processedTrackCount == selectedTracks.count)
}
}
