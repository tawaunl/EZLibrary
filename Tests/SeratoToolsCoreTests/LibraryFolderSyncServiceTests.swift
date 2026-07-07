import Foundation
import Testing
@testable import SeratoToolsCore

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