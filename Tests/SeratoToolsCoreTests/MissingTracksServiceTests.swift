import Testing
import Foundation
@testable import SeratoToolsCore

private func missingTracksFixture(_ path: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent(path)
}

private func makeScratchDatabaseCopy() throws -> (databaseFile: URL, tempRoot: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-missing-tracks-tests-\(UUID().uuidString)")
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

    let databaseFile = libraryDirectory.appendingPathComponent("database V2")
    try FileManager.default.copyItem(at: missingTracksFixture("database V2"), to: databaseFile)
    return (databaseFile, tempRoot)
}

@Suite(.serialized)
struct MissingTracksServiceTests {
    @Test func preferredMatchPicksCandidateInsidePreferredDirectory() async throws {
        let oldBackupDirectory = SeratoBackupBeforeWrite.backupDirectory
        let scratch = try makeScratchDatabaseCopy()
        defer {
            SeratoBackupBeforeWrite.backupDirectory = oldBackupDirectory
            try? FileManager.default.removeItem(at: scratch.tempRoot)
        }

        SeratoBackupBeforeWrite.backupDirectory = scratch.tempRoot.appendingPathComponent("Backups")

        let parseRoot = URL(fileURLWithPath: "/Volumes/Crucial X10")
        let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: parseRoot)
        let target = try #require(tracks.first)

        let preferredDir = scratch.tempRoot.appendingPathComponent("Preferred", isDirectory: true)
        let otherDir = scratch.tempRoot.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: preferredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let preferredMatch = preferredDir.appendingPathComponent(target.fileURL.lastPathComponent)
        let otherMatch = otherDir.appendingPathComponent(target.fileURL.lastPathComponent)
        try Data("preferred".utf8).write(to: preferredMatch)
        try Data("other".utf8).write(to: otherMatch)

        let candidate = MissingTrackCandidate(track: target, matches: [otherMatch, preferredMatch])
        let service = await MainActor.run {
            MissingTracksService(rootDirectory: scratch.tempRoot, databaseFileURL: scratch.databaseFile)
        }

        let resolvedPreferred = await MainActor.run {
            service.preferredMatch(for: candidate, preferredDirectory: preferredDir)
        }
        #expect(resolvedPreferred == preferredMatch)
    }

    @Test func repairAllUsingPreferredLocationSkipsTracksWithoutPreferredMatch() async throws {
        let oldBackupDirectory = SeratoBackupBeforeWrite.backupDirectory
        let scratch = try makeScratchDatabaseCopy()
        defer {
            SeratoBackupBeforeWrite.backupDirectory = oldBackupDirectory
            try? FileManager.default.removeItem(at: scratch.tempRoot)
        }

        SeratoBackupBeforeWrite.backupDirectory = scratch.tempRoot.appendingPathComponent("Backups")

        let parseRoot = URL(fileURLWithPath: "/Volumes/Crucial X10")
        let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: parseRoot)
        let selectedTracks = Array(tracks.prefix(2))
        #expect(selectedTracks.count == 2)

        let preferredDir = scratch.tempRoot.appendingPathComponent("Preferred", isDirectory: true)
        let otherDir = scratch.tempRoot.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: preferredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let firstPreferredMatch = preferredDir.appendingPathComponent(selectedTracks[0].fileURL.lastPathComponent)
        let secondOtherMatch = otherDir.appendingPathComponent(selectedTracks[1].fileURL.lastPathComponent)
        try Data("first".utf8).write(to: firstPreferredMatch)
        try Data("second".utf8).write(to: secondOtherMatch)

        let service = await MainActor.run {
            MissingTracksService(rootDirectory: scratch.tempRoot, databaseFileURL: scratch.databaseFile)
        }
        await MainActor.run {
            service.detectMissingTracks(in: selectedTracks)
        }
        await service.scanForMatches(roots: [preferredDir, otherDir])

        let repairedCount = try await MainActor.run {
            try service.repairAllUsingPreferredLocation(preferredDir)
        }
        #expect(repairedCount == 1)

        let remainingIDs = await MainActor.run {
            Set(service.candidates.map(\.id))
        }
        #expect(remainingIDs.contains(selectedTracks[1].id))
        #expect(!remainingIDs.contains(selectedTracks[0].id))

        let reparsed = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.tempRoot)
        let firstExpectedPath = SeratoLibraryLocator.seratoStoredPath(for: firstPreferredMatch, rootDirectory: scratch.tempRoot)
        #expect(reparsed.contains { $0.seratoStoredPath == firstExpectedPath })
    }

    @Test func deleteFromLibraryRemovesTrackAndCandidate() async throws {
        let oldBackupDirectory = SeratoBackupBeforeWrite.backupDirectory
        let scratch = try makeScratchDatabaseCopy()
        defer {
            SeratoBackupBeforeWrite.backupDirectory = oldBackupDirectory
            try? FileManager.default.removeItem(at: scratch.tempRoot)
        }

        SeratoBackupBeforeWrite.backupDirectory = scratch.tempRoot.appendingPathComponent("Backups")

        let parseRoot = URL(fileURLWithPath: "/Volumes/Crucial X10")
        let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: parseRoot)
        let targetTrack = try #require(tracks.first)

        let service = await MainActor.run {
            MissingTracksService(rootDirectory: scratch.tempRoot, databaseFileURL: scratch.databaseFile)
        }
        await MainActor.run {
            service.detectMissingTracks(in: [targetTrack])
        }

        let deleted = try await MainActor.run {
            let targetCandidate = try #require(service.candidates.first)
            return try service.deleteFromLibrary(targetCandidate, in: [])
        }
        #expect(deleted)

        let remainingCandidateCount = await MainActor.run { service.candidates.count }
        #expect(remainingCandidateCount == 0)

        let reparsed = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.tempRoot)
        #expect(!reparsed.contains { $0.seratoStoredPath == targetTrack.seratoStoredPath })
    }

    @Test func deleteAllWithoutMatchesRemovesOnlyUnmatchedTracks() async throws {
        let oldBackupDirectory = SeratoBackupBeforeWrite.backupDirectory
        let scratch = try makeScratchDatabaseCopy()
        defer {
            SeratoBackupBeforeWrite.backupDirectory = oldBackupDirectory
            try? FileManager.default.removeItem(at: scratch.tempRoot)
        }

        SeratoBackupBeforeWrite.backupDirectory = scratch.tempRoot.appendingPathComponent("Backups")

        let parseRoot = URL(fileURLWithPath: "/Volumes/Crucial X10")
        let tracks = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: parseRoot)
        let selectedTracks = Array(tracks.prefix(2))
        #expect(selectedTracks.count == 2)

        let preferredDir = scratch.tempRoot.appendingPathComponent("Preferred", isDirectory: true)
        try FileManager.default.createDirectory(at: preferredDir, withIntermediateDirectories: true)

        let matchedTrack = selectedTracks[0]
        let unmatchedTrack = selectedTracks[1]
        let matchedFile = preferredDir.appendingPathComponent(matchedTrack.fileURL.lastPathComponent)
        try Data("matched".utf8).write(to: matchedFile)

        let service = await MainActor.run {
            MissingTracksService(rootDirectory: scratch.tempRoot, databaseFileURL: scratch.databaseFile)
        }
        await MainActor.run {
            service.detectMissingTracks(in: selectedTracks)
        }
        await service.scanForMatches(roots: [preferredDir])

        let deletedCount = try await MainActor.run {
            try service.deleteAllWithoutMatches(in: [])
        }
        #expect(deletedCount == 1)

        let remainingCount = await MainActor.run { service.candidates.count }
        #expect(remainingCount == 1)

        let reparsed = try SeratoDatabaseParser.parseTracks(at: scratch.databaseFile, rootDirectory: scratch.tempRoot)
        #expect(reparsed.contains { $0.seratoStoredPath == matchedTrack.seratoStoredPath })
        #expect(!reparsed.contains { $0.seratoStoredPath == unmatchedTrack.seratoStoredPath })
    }
}
