import Testing
import Foundation
@testable import EZLibraryCore

private func backupFixture(_ path: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent(path)
}

private func makeScratchBackupLibrary() throws -> (libraryDirectory: URL, rootDirectory: URL, tracks: [Track], crates: [Crate]) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-backup-test-\(UUID().uuidString)")
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    let subcratesDirectory = libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
    try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)

    let databaseFile = libraryDirectory.appendingPathComponent("database V2")
    let crateFile = subcratesDirectory.appendingPathComponent("Mike's Party.crate")
    try FileManager.default.copyItem(at: backupFixture("database V2"), to: databaseFile)
    try FileManager.default.copyItem(at: backupFixture("Subcrates/Mike's Party.crate"), to: crateFile)

    let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: tempRoot)
    let crate = try SeratoCrateParser.parseCrate(at: crateFile)
    return (libraryDirectory, tempRoot, tracks, [crate])
}

private func relativePath(from url: URL, baseURL: URL) -> String {
    let basePath = baseURL.standardizedFileURL.path
    var path = url.standardizedFileURL.path
    if path.hasPrefix(basePath) {
        path.removeFirst(basePath.count)
    }
    while path.hasPrefix("/") {
        path.removeFirst()
    }
    return path
}

private let fixedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

@Suite(.serialized)
struct LibraryBackupServiceTests {
    @Test func fullBackupCopiesSeratoFolderAndTracks() throws {
        let scratch = try makeScratchBackupLibrary()
        defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

        let selectedTracks = Array(scratch.tracks.prefix(2))
        for track in selectedTracks {
            try FileManager.default.createDirectory(at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(track.seratoStoredPath.utf8).write(to: track.fileURL)
        }

        let destination = scratch.rootDirectory.appendingPathComponent("Backups", isDirectory: true)
        let result = try LibraryBackupService.backup(
            destinationFolderURL: destination,
            mode: .full,
            tracks: selectedTracks,
            crates: scratch.crates,
            libraryDirectory: scratch.libraryDirectory,
            rootDirectory: scratch.rootDirectory,
            timestamp: fixedTimestamp
        )

        #expect(result.copiedSeratoFolder)
        #expect(result.copiedTrackCount == selectedTracks.count)
        #expect(FileManager.default.fileExists(atPath: result.backupRootURL.appendingPathComponent("Serato/_Serato_/database V2").path))

        for track in selectedTracks {
            let expectedURL = result.backupRootURL
                .appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent(relativePath(from: track.fileURL, baseURL: scratch.rootDirectory))
            #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        }
    }

    @Test func incrementalBackupSkipsTracksFromPreviousBackup() throws {
        let scratch = try makeScratchBackupLibrary()
        defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

        let firstBatch = Array(scratch.tracks.prefix(2))
        let thirdTrack = try #require(scratch.tracks.dropFirst(2).first)

        for track in firstBatch + [thirdTrack] {
            try FileManager.default.createDirectory(at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(track.seratoStoredPath.utf8).write(to: track.fileURL)
        }

        let destination = scratch.rootDirectory.appendingPathComponent("Backups", isDirectory: true)
        _ = try LibraryBackupService.backup(
            destinationFolderURL: destination,
            mode: .full,
            tracks: firstBatch,
            crates: scratch.crates,
            libraryDirectory: scratch.libraryDirectory,
            rootDirectory: scratch.rootDirectory,
            timestamp: fixedTimestamp
        )

        let incrementalResult = try LibraryBackupService.backup(
            destinationFolderURL: destination,
            mode: .incremental,
            tracks: firstBatch + [thirdTrack],
            crates: scratch.crates,
            libraryDirectory: scratch.libraryDirectory,
            rootDirectory: scratch.rootDirectory,
            timestamp: fixedTimestamp.addingTimeInterval(60)
        )

        #expect(incrementalResult.copiedTrackCount == 1)
        #expect(incrementalResult.skippedTrackCount == 2)
    }

    @Test func singleCrateBackupPackagesSelectedCrateAndTracks() throws {
        let scratch = try makeScratchBackupLibrary()
        defer { try? FileManager.default.removeItem(at: scratch.rootDirectory) }

        let crate = try #require(scratch.crates.first)
        let selectedPaths = Array(crate.trackPaths.prefix(2))
        let selectedTracks = scratch.tracks.filter { selectedPaths.contains($0.seratoStoredPath) }

        for track in selectedTracks {
            try FileManager.default.createDirectory(at: track.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(track.seratoStoredPath.utf8).write(to: track.fileURL)
        }

        let destination = scratch.rootDirectory.appendingPathComponent("Backups", isDirectory: true)
        let result = try LibraryBackupService.backup(
            destinationFolderURL: destination,
            mode: .singleCrate,
            tracks: scratch.tracks,
            crates: scratch.crates,
            selectedCrateID: crate.id,
            libraryDirectory: scratch.libraryDirectory,
            rootDirectory: scratch.rootDirectory,
            timestamp: fixedTimestamp
        )

        #expect(result.copiedSeratoFolder == false)
        #expect(result.copiedCrateCount == 1)
        #expect(result.backupRootURL.lastPathComponent.contains("Mike's Party"))
        #expect(FileManager.default.fileExists(atPath: result.backupRootURL.appendingPathComponent("Crates/Subcrates/Mike's Party.crate").path))
    }
}