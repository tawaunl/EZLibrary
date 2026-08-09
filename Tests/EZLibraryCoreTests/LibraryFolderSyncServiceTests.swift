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

private func makeSyncScratchEnvironment() throws -> (tempRoot: URL, libraryDirectory: URL, destinationRoot: URL, databaseFile: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-sync-folder-test-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    let destinationRoot = tempRoot.appendingPathComponent("Main Music", isDirectory: true)
    let databaseFile = libraryDirectory.appendingPathComponent("database V2")

    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

    let fixture = Bundle.module
        .url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent("database V2")
    try FileManager.default.copyItem(at: fixture, to: databaseFile)

    return (tempRoot, libraryDirectory, destinationRoot, databaseFile)
}

@Test func syncAudioFolderInsertsMissingTracks() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let fileA = env.destinationRoot.appendingPathComponent("Sync A.mp3")
    let fileB = env.destinationRoot.appendingPathComponent("Sync B.aiff")
    try Data("a".utf8).write(to: fileA)
    try Data("b".utf8).write(to: fileB)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.scannedAudioFiles == 2)
    #expect(result.insertedTracks == 2)
    #expect(result.alreadyPresentTracks == 0)
}

@Test func syncAudioFolderIsIdempotentOnSecondRun() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let fileA = env.destinationRoot.appendingPathComponent("Sync A.mp3")
    try Data("a".utf8).write(to: fileA)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    _ = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let second = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(second.scannedAudioFiles == 1)
    #expect(second.insertedTracks == 0)
    #expect(second.alreadyPresentTracks == 1)
}

@Test func syncAudioFolderUsesFilenameFallbackForArtistAndTitle() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("01 DJ Example - Sunset Mix.mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.insertedTracks == 1)

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "DJ Example")
    #expect(insertedTrack.title == "Sunset Mix")
}

@Test func syncAudioFilesInsertsOnlyProvidedFiles() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let included = env.destinationRoot.appendingPathComponent("Artist One - Kept Song.mp3")
    let excluded = env.destinationRoot.appendingPathComponent("Artist Two - Not Synced.mp3")
    try Data("included".utf8).write(to: included)
    try Data("excluded".utf8).write(to: excluded)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFiles(
        [included],
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.scannedAudioFiles == 1)
    #expect(result.insertedTracks == 1)

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let includedPath = SeratoLibraryLocator.seratoStoredPath(for: included, rootDirectory: rootDirectory)
    let excludedPath = SeratoLibraryLocator.seratoStoredPath(for: excluded, rootDirectory: rootDirectory)

    #expect(tracks.contains(where: { $0.seratoStoredPath == includedPath }))
    #expect(!tracks.contains(where: { $0.seratoStoredPath == excludedPath }))
}

@Test func syncAudioFolderParsesFeaturedArtistAndStripsTrailingDescriptors() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("07 Artist ft Guest - Big Tune [Intro] (Extended Mix).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.insertedTracks == 1)

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "Artist feat. Guest")
    #expect(insertedTrack.title == "Big Tune [Intro] (Extended Mix)")
}

@Test func syncAudioFolderStripsCommonVideoNoiseFromTitle() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("Artist Name - Anthem - Official Video [HD].mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "Artist Name")
    #expect(insertedTrack.title == "Anthem")
}

@Test func syncAudioFolderParsesCompactArtistTitleSeparator() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("DJNova-SunriseCut.mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "DJNova")
    #expect(insertedTrack.title == "SunriseCut")
}

@Test func syncAudioFolderPreservesDJDescriptorsInTitle() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("Artist Name - Anthem (Official Video) [Quick Hit Intro] (Extended Remix Edit).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "Artist Name")
    #expect(insertedTrack.title == "Anthem [Quick Hit Intro] (Extended Remix Edit)")
}

@Test func syncAudioFolderPreservesAdditionalDJDescriptorsInTitle() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("DJ Metro - Night Run (Official Audio) [Transition] (Bootleg Mashup Acapella Edit).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let storedPath = SeratoLibraryLocator.seratoStoredPath(for: file, rootDirectory: rootDirectory)
    let insertedTrack = try #require(tracks.first(where: { $0.seratoStoredPath == storedPath }))

    #expect(insertedTrack.artist == "DJ Metro")
    #expect(insertedTrack.title == "Night Run [Transition] (Bootleg Mashup Acapella Edit)")
}
// MARK: - Path conventions, tags, and the naming template

/// A library holds both stored-path conventions. Matching them as raw strings
/// meant a track already in the database under the other convention was never
/// recognised, so every sync appended a second entry for the same file — the
/// duplicates users saw after syncing a folder on an external drive.
@Test func syncDoesNotDuplicateTracksStoredInTheOtherPathConvention() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("Calvin Harris - Feel So Close.mp3")
    try Data("a".utf8).write(to: file)

    // A library kept on a volume: paths are stored relative to the mount point.
    let rootDirectory = SeratoLibraryLocator.rootDirectory(
        for: env.libraryDirectory,
        homeDirectory: URL(fileURLWithPath: "/nonexistent-home")
    )
    #expect(rootDirectory.path != "/")

    // Seed the entry in the *filesystem-root-relative* form instead.
    var data = try Data(contentsOf: env.databaseFile)
    data = SeratoDatabaseWriter.appendingTrack(
        storedPath: String(file.standardizedFileURL.path.dropFirst()),
        metadata: SeratoTrackMetadataUpdate(
            title: "Feel So Close", artist: "Calvin Harris", album: "18 Months",
            genre: "Dance", comment: "", key: "", bpm: 128, year: 2012
        ),
        to: data
    )
    try data.write(to: env.databaseFile)
    let seededCount = SeratoDatabaseParser.storedPaths(from: data).count

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.insertedTracks == 0)
    #expect(result.alreadyPresentTracks == 1)

    let after = SeratoDatabaseParser.storedPaths(from: try Data(contentsOf: env.databaseFile))
    #expect(after.count == seededCount)
}

/// The naming template the user configured is used to read a filename back,
/// rather than the generic "Artist - Title" heuristic.
@Test func filenameMetadataFollowsTheConfiguredTemplate() {
    let parsed = LibraryFolderSyncService.metadataMatchingTemplate(
        "Avicii-Levels-True-2011",
        template: "{artist}-{title}-{album}-{year}"
    )

    #expect(parsed?.artist == "Avicii")
    #expect(parsed?.title == "Levels")
    #expect(parsed?.album == "True")
    #expect(parsed?.year == 2011)
}

@Test func templateParsingHandlesADifferentTokenOrderAndSeparator() {
    let parsed = LibraryFolderSyncService.metadataMatchingTemplate(
        "Levels — Avicii",
        template: "{title} — {artist}"
    )

    #expect(parsed?.title == "Levels")
    #expect(parsed?.artist == "Avicii")
}

/// A name that doesn't fit the template must fall back rather than write a bad
/// split into the database.
@Test func templateParsingDeclinesNamesThatDoNotFit() {
    let template = "{artist}-{title}-{album}-{year}"

    // Too few segments.
    #expect(LibraryFolderSyncService.metadataMatchingTemplate("Just A Name", template: template) == nil)
    // The {year} slot isn't a number.
    #expect(
        LibraryFolderSyncService.metadataMatchingTemplate(
            "Calvin Harris-Feel So Close-18 Months-notayear", template: template
        ) == nil
    )
    // More segments than the template has tokens.
    #expect(
        LibraryFolderSyncService.metadataMatchingTemplate(
            "A-B-C-2011-extra", template: template
        ) == nil
    )
}

/// Falls back to the heuristic when the name doesn't match the template, so
/// the long-standing "Artist - Title" behaviour is preserved.
@Test func filenameMetadataFallsBackToHeuristicWhenTemplateDoesNotMatch() {
    let metadata = LibraryFolderSyncService.filenameMetadata(
        for: URL(fileURLWithPath: "/tmp/Calvin Harris - Feel So Close (Official Video).mp3"),
        template: "{artist}-{title}-{album}-{year}"
    )

    #expect(metadata.artist == "Calvin Harris")
    #expect(metadata.title == "Feel So Close")
}

/// Importing a file whose name is already taken produces "Song (2).mp3". That
/// suffix is a filesystem artifact, so it must not survive into a tag —
/// tracks were ending up with a stray "2" in the title.
@Test func collisionSuffixIsStrippedFromGuessedMetadata() {
    #expect(LibraryFolderSyncService.strippingCollisionSuffix("Titanium - Sia (2)") == "Titanium - Sia")
    #expect(LibraryFolderSyncService.strippingCollisionSuffix("Song (12)") == "Song")
    // Repeated collisions.
    #expect(LibraryFolderSyncService.strippingCollisionSuffix("Song (2) (3)") == "Song")
    // A meaningful parenthetical is left alone.
    #expect(LibraryFolderSyncService.strippingCollisionSuffix("Song (Intro)") == "Song (Intro)")
    #expect(LibraryFolderSyncService.strippingCollisionSuffix("Song (2012)") == "Song (2012)")

    // It is removed before parsing, so whichever field the template puts last
    // doesn't inherit it either.
    let metadata = LibraryFolderSyncService.filenameMetadata(
        for: URL(fileURLWithPath: "/tmp/Titanium - Sia (2).mp3"),
        template: "{title} - {artist}"
    )
    #expect(metadata.title == "Titanium")
    #expect(metadata.artist == "Sia")
}

/// The heuristic assumed "Artist - Title" regardless of how the user actually
/// names files, so a title-first library came out with the two swapped.
@Test func titleFirstTemplateIsNotReadAsArtistFirst() {
    let metadata = LibraryFolderSyncService.filenameMetadata(
        for: URL(fileURLWithPath: "/tmp/Feel So Close - Calvin Harris.mp3"),
        template: "{title} - {artist}"
    )

    #expect(metadata.title == "Feel So Close")
    #expect(metadata.artist == "Calvin Harris")
}

/// The sync reports which files it added so the caller can file only those in
/// a crate, rather than everything it scanned.
@Test func syncReportsOnlyNewlyInsertedFiles() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let existing = env.destinationRoot.appendingPathComponent("Already There.mp3")
    try Data("a".utf8).write(to: existing)
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let first = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot, databaseFileURL: env.databaseFile, rootDirectory: rootDirectory
    )
    #expect(first.insertedFileURLs.count == 1)

    // A second file arrives; only it should be reported.
    let arrival = env.destinationRoot.appendingPathComponent("Brand New.mp3")
    try Data("b".utf8).write(to: arrival)

    let second = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot, databaseFileURL: env.databaseFile, rootDirectory: rootDirectory
    )

    #expect(second.scannedAudioFiles == 2)
    #expect(second.alreadyPresentTracks == 1)
    #expect(second.insertedFileURLs.map(\.lastPathComponent) == ["Brand New.mp3"])
}

// MARK: - Renaming from tags

/// Renaming is off unless asked for, so a plain sync never touches filenames.
@Test func syncLeavesFilenamesAloneByDefault() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("whatever.mp3")
    try Data("a".utf8).write(to: file)
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot, databaseFileURL: env.databaseFile, rootDirectory: rootDirectory
    )

    #expect(result.renamedFiles.isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

/// A file with no readable tags is never renamed, even with renaming on: the
/// only name available would come from the filename being replaced.
@Test func syncDoesNotRenameFilesWithoutTags() async throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    // Not real audio, so there are no tags to read.
    let file = env.destinationRoot.appendingPathComponent("Some Artist - Some Title.mp3")
    try Data("not audio".utf8).write(to: file)
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try await LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory,
        filenameTemplate: "{artist}-{title}",
        renameFilesFromTags: true
    )

    #expect(result.insertedTracks == 1)
    #expect(result.renamedFiles.isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

/// The proposed name follows the template, and a file already named correctly
/// is left alone rather than being "renamed" to itself.
@Test func proposedRenameFollowsTheTemplate() {
    let metadata = SeratoTrackMetadataUpdate(
        title: "Feel So Close", artist: "Calvin Harris", album: "18 Months",
        genre: "Dance", comment: "", key: "", bpm: nil, year: 2012
    )

    let proposed = LibraryFolderSyncService.proposedRenameURL(
        for: URL(fileURLWithPath: "/tmp/junk name.mp3"),
        metadata: metadata,
        template: "{artist} - {title}"
    )
    #expect(proposed?.lastPathComponent == "Calvin Harris - Feel So Close.mp3")

    // Already correct -> nothing proposed.
    let noop = LibraryFolderSyncService.proposedRenameURL(
        for: URL(fileURLWithPath: "/tmp/Calvin Harris - Feel So Close.mp3"),
        metadata: metadata,
        template: "{artist} - {title}"
    )
    #expect(noop == nil)

    // Nothing to build a name from -> nothing proposed.
    let empty = LibraryFolderSyncService.proposedRenameURL(
        for: URL(fileURLWithPath: "/tmp/x.mp3"),
        metadata: SeratoTrackMetadataUpdate(
            title: "", artist: "", album: "", genre: "", comment: "", key: "", bpm: nil, year: nil
        ),
        template: "{artist} - {title}"
    )
    #expect(empty == nil)
}
