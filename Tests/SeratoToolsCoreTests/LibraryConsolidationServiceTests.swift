import Testing
import Foundation
@testable import SeratoToolsCore

private func consolidationFixture(_ path: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent(path)
}

private func makeScratchLibrary() throws -> (libraryDirectory: URL, databaseFile: URL, crateFile: URL, rootDirectory: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-library-consolidation-\(UUID().uuidString)")
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    let subcratesDirectory = libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)

    try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)

    let databaseFile = libraryDirectory.appendingPathComponent("database V2")
    let crateFile = subcratesDirectory.appendingPathComponent("Mike's Party.crate")

    try FileManager.default.copyItem(at: consolidationFixture("database V2"), to: databaseFile)
    try FileManager.default.copyItem(at: consolidationFixture("Subcrates/Mike's Party.crate"), to: crateFile)
    return (libraryDirectory, databaseFile, crateFile, tempRoot)
}

@Suite(.serialized)
struct LibraryConsolidationServiceTests {

@Test func databaseWriterCanRewriteMultiplePathsInOnePass() throws {
    let databaseFile = consolidationFixture("database V2")
    let rootDirectory = URL(fileURLWithPath: "/Volumes/Crucial X10")
    let originalData = try Data(contentsOf: databaseFile)
    let tracks = SeratoDatabaseParser.parseTracks(from: originalData, rootDirectory: rootDirectory)
    let targets = Array(try #require(tracks.prefix(2).count == 2 ? tracks.prefix(2) : nil))

    let pathMap = Dictionary(uniqueKeysWithValues: targets.map { track in
        (track.seratoStoredPath, track.seratoStoredPath + ".MOVED")
    })

    let rewritten = SeratoDatabaseWriter.rewritingPaths(pathMap, in: originalData)
    #expect(rewritten.rewrittenCount == 2)

    let reparsed = SeratoDatabaseParser.parseTracks(from: rewritten.data, rootDirectory: rootDirectory)
    for target in targets {
        #expect(reparsed.contains { $0.seratoStoredPath == target.seratoStoredPath + ".MOVED" })
    }
}

@Test func consolidateMovesFilesAndRewritesDatabaseAndCrates() throws {
    let scratch = try makeScratchLibrary()
    defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

    SeratoBackupBeforeWrite.backupDirectory = scratch.rootDirectory.appendingPathComponent("Backups")

    let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.rootDirectory)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)
    let selectedPaths = Array(crate.trackPaths.prefix(2))
    #expect(selectedPaths.count == 2)

    let selectedTracks = tracks.filter { selectedPaths.contains($0.seratoStoredPath) }
    #expect(selectedTracks.count == selectedPaths.count)

    for track in selectedTracks {
        let directory = track.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: track.fileURL)
    }

    let destinationFolder = scratch.rootDirectory.appendingPathComponent("Consolidated Music", isDirectory: true)
    let preview = LibraryConsolidationService.preview(
        tracks: selectedTracks,
        destinationFolderURL: destinationFolder,
        homeDirectory: scratch.rootDirectory
    )
    #expect(preview.totalMoves == selectedTracks.count)

    let result = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.rootDirectory,
        databaseFileURL: scratch.databaseFile
    )

    #expect(result.processedTrackCount == selectedTracks.count)
    #expect(result.updatedCrateCount == 1)

    let reparsedTracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.rootDirectory)
    let reparsedCrate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)

    for move in preview.moves {
        let expectedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: move.destinationURL, rootDirectory: scratch.rootDirectory)
        #expect(FileManager.default.fileExists(atPath: move.destinationURL.path))
        #expect(reparsedTracks.contains { $0.seratoStoredPath == expectedStoredPath })
        #expect(reparsedCrate.trackPaths.contains(expectedStoredPath))
    }
}

@Test func consolidationFlattensFilesIntoSingleDestinationFolder() throws {
    let scratch = try makeScratchLibrary()
    defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

    SeratoBackupBeforeWrite.backupDirectory = scratch.rootDirectory.appendingPathComponent("Backups")

    let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.rootDirectory)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)

    let selectedTracks = tracks.filter { crate.trackPaths.contains($0.seratoStoredPath) }
    #expect(selectedTracks.count >= 2)

    for track in selectedTracks {
        let directory = track.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: track.fileURL)
    }

    let destinationFolder = scratch.rootDirectory.appendingPathComponent("Flat Consolidated Music", isDirectory: true)
    let preview = LibraryConsolidationService.preview(
        tracks: selectedTracks,
        destinationFolderURL: destinationFolder,
        homeDirectory: scratch.rootDirectory
    )

    #expect(preview.moves.allSatisfy { $0.destinationURL.deletingLastPathComponent() == destinationFolder.standardizedFileURL })
    #expect(preview.moves.allSatisfy { !$0.destinationURL.path.replacingOccurrences(of: destinationFolder.standardizedFileURL.path + "/", with: "").contains("/") })

    let result = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.rootDirectory,
        databaseFileURL: scratch.databaseFile
    )

    #expect(result.processedTrackCount == selectedTracks.count)
    #expect(result.updatedCrateCount == 1)
    #expect((try FileManager.default.contentsOfDirectory(at: destinationFolder, includingPropertiesForKeys: nil)).allSatisfy { $0.hasDirectoryPath == false })
}

@Test func consolidationHandlesNestedSourceFoldersAndStillFlattensDestination() throws {
    let scratch = try makeScratchLibrary()
    defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

    SeratoBackupBeforeWrite.backupDirectory = scratch.rootDirectory.appendingPathComponent("Backups")

    let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.rootDirectory)
    let crate = try SeratoCrateParser.parseCrate(at: scratch.crateFile)
    var selectedTracks = Array(tracks.filter { crate.trackPaths.contains($0.seratoStoredPath) }.prefix(2))
    #expect(selectedTracks.count == 2)

    let sourceFolders = [
        scratch.rootDirectory.appendingPathComponent("Music/Collection/A/Deep", isDirectory: true),
        scratch.rootDirectory.appendingPathComponent("Music/Collection/B/Deep", isDirectory: true)
    ]

    for (index, _) in selectedTracks.enumerated() {
        let fileURL = sourceFolders[index].appendingPathComponent("nested-track-\(index + 1).mp3")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: fileURL)
        selectedTracks[index].fileURL = fileURL
    }

    let destinationFolder = scratch.rootDirectory.appendingPathComponent("Nested Flat Consolidated Music", isDirectory: true)
    let preview = LibraryConsolidationService.preview(
        tracks: Array(selectedTracks),
        destinationFolderURL: destinationFolder,
        homeDirectory: scratch.rootDirectory
    )

    #expect(preview.sourceGroups.count == 2)
    #expect(preview.moves.allSatisfy { $0.destinationURL.deletingLastPathComponent() == destinationFolder.standardizedFileURL })

    let result = try LibraryConsolidationService.consolidate(
        preview: preview,
        mode: .move,
        crates: [Crate(pathComponents: crate.pathComponents, trackPaths: crate.trackPaths, fileURL: scratch.crateFile)],
        rootDirectory: scratch.rootDirectory,
        databaseFileURL: scratch.databaseFile
    )

    #expect(result.processedTrackCount == selectedTracks.count)
    #expect(result.updatedCrateCount == 1)

    let destinationEntries = try FileManager.default.contentsOfDirectory(at: destinationFolder, includingPropertiesForKeys: nil)
    #expect(destinationEntries.allSatisfy { $0.hasDirectoryPath == false })
}

}