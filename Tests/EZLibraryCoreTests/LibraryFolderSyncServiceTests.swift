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

@Test func syncAudioFolderInsertsMissingTracks() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let fileA = env.destinationRoot.appendingPathComponent("Sync A.mp3")
    let fileB = env.destinationRoot.appendingPathComponent("Sync B.aiff")
    try Data("a".utf8).write(to: fileA)
    try Data("b".utf8).write(to: fileB)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(result.scannedAudioFiles == 2)
    #expect(result.insertedTracks == 2)
    #expect(result.alreadyPresentTracks == 0)
}

@Test func syncAudioFolderIsIdempotentOnSecondRun() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let fileA = env.destinationRoot.appendingPathComponent("Sync A.mp3")
    try Data("a".utf8).write(to: fileA)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    _ = try LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    let second = try LibraryFolderSyncService.syncAudioFolder(
        env.destinationRoot,
        databaseFileURL: env.databaseFile,
        rootDirectory: rootDirectory
    )

    #expect(second.scannedAudioFiles == 1)
    #expect(second.insertedTracks == 0)
    #expect(second.alreadyPresentTracks == 1)
}

@Test func syncAudioFolderUsesFilenameFallbackForArtistAndTitle() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("01 DJ Example - Sunset Mix.mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try LibraryFolderSyncService.syncAudioFolder(
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

@Test func syncAudioFilesInsertsOnlyProvidedFiles() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let included = env.destinationRoot.appendingPathComponent("Artist One - Kept Song.mp3")
    let excluded = env.destinationRoot.appendingPathComponent("Artist Two - Not Synced.mp3")
    try Data("included".utf8).write(to: included)
    try Data("excluded".utf8).write(to: excluded)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try LibraryFolderSyncService.syncAudioFiles(
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

@Test func syncAudioFolderParsesFeaturedArtistAndStripsTrailingDescriptors() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("07 Artist ft Guest - Big Tune [Intro] (Extended Mix).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try LibraryFolderSyncService.syncAudioFolder(
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

@Test func syncAudioFolderStripsCommonVideoNoiseFromTitle() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("Artist Name - Anthem - Official Video [HD].mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try LibraryFolderSyncService.syncAudioFolder(
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

@Test func syncAudioFolderParsesCompactArtistTitleSeparator() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("DJNova-SunriseCut.mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try LibraryFolderSyncService.syncAudioFolder(
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

@Test func syncAudioFolderPreservesDJDescriptorsInTitle() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("Artist Name - Anthem (Official Video) [Quick Hit Intro] (Extended Remix Edit).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try LibraryFolderSyncService.syncAudioFolder(
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

@Test func syncAudioFolderPreservesAdditionalDJDescriptorsInTitle() throws {
    let env = try makeSyncScratchEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let file = env.destinationRoot.appendingPathComponent("DJ Metro - Night Run (Official Audio) [Transition] (Bootleg Mashup Acapella Edit).mp3")
    try Data("track".utf8).write(to: file)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)
    _ = try LibraryFolderSyncService.syncAudioFolder(
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