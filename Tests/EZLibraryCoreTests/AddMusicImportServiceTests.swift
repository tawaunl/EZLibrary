import Foundation
import Testing
@testable import EZLibraryCore

private func makeScratchImportEnvironment() throws -> (tempRoot: URL, libraryDirectory: URL, subcratesDirectory: URL, destinationRoot: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-add-music-test-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    let subcratesDirectory = libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
    let destinationRoot = tempRoot.appendingPathComponent("Main Music", isDirectory: true)

    try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

    return (tempRoot, libraryDirectory, subcratesDirectory, destinationRoot)
}

@Test func discoverAudioFilesFindsSupportedFormatsRecursively() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let sourceFolder = env.tempRoot.appendingPathComponent("Incoming", isDirectory: true)
    let nestedFolder = sourceFolder.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)

    let fileA = sourceFolder.appendingPathComponent("Track 01.mp3")
    let fileB = nestedFolder.appendingPathComponent("Track 02.WAV")
    let nonAudio = nestedFolder.appendingPathComponent("Readme.txt")

    try Data("a".utf8).write(to: fileA)
    try Data("b".utf8).write(to: fileB)
    try Data("notes".utf8).write(to: nonAudio)

    let discovered = AddMusicImportService.discoverAudioFiles(from: [sourceFolder, fileA])
    let discoveredPaths = Set(discovered.map(\.path))

    #expect(discovered.count == 2)
    #expect(discoveredPaths.contains(fileA.path))
    #expect(discoveredPaths.contains(fileB.path))
    #expect(!discoveredPaths.contains(nonAudio.path))
}

@Test func importIntoDatedCrateMovesFilesAndCreatesCrate() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let incomingFolder = env.tempRoot.appendingPathComponent("Downloads Batch", isDirectory: true)
    let nested = incomingFolder.appendingPathComponent("House", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let sourceFileA = incomingFolder.appendingPathComponent("Song A.mp3")
    let sourceFileB = nested.appendingPathComponent("Song B.aiff")
    try Data("track-a".utf8).write(to: sourceFileA)
    try Data("track-b".utf8).write(to: sourceFileB)

    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 1
    components.day = 1
    let fixedDate = try #require(components.date)
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try AddMusicImportService.importIntoDatedCrate(
        inputURLs: [incomingFolder],
        destinationFolderURL: env.destinationRoot,
        crateNamePrefix: "New Music",
        transferMode: .move,
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory,
        date: fixedDate
    )

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let expectedDatedName = "New Music \(formatter.string(from: fixedDate))"

    #expect(result.importedTrackCount == 2)
    #expect(FileManager.default.fileExists(atPath: result.crateFileURL.path))
    #expect(result.crateName == expectedDatedName)
    #expect(result.destinationFolderURL == env.destinationRoot)

    #expect(!FileManager.default.fileExists(atPath: sourceFileA.path))
    #expect(!FileManager.default.fileExists(atPath: sourceFileB.path))

    let importedFiles = try FileManager.default.contentsOfDirectory(at: env.destinationRoot, includingPropertiesForKeys: nil)
    #expect(importedFiles.count == 2)

    let crate = try SeratoCrateParser.parseCrate(at: result.crateFileURL)
    let expectedStoredPaths = Set(importedFiles.map {
        SeratoLibraryLocator.seratoStoredPath(for: $0, rootDirectory: rootDirectory)
    })
    #expect(Set(crate.trackPaths) == expectedStoredPaths)
}

@Test func importIntoDatedCrateAllowsImportWhileSeratoIsRunning() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    SeratoProcessGuard.isRunningOverride = true
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let incomingFile = env.tempRoot.appendingPathComponent("Live Add.mp3")
    try Data("live".utf8).write(to: incomingFile)

    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 1
    components.day = 2
    let fixedDate = try #require(components.date)
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try AddMusicImportService.importIntoDatedCrate(
        inputURLs: [incomingFile],
        destinationFolderURL: env.destinationRoot,
        crateNamePrefix: "New Music",
        transferMode: .move,
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory,
        date: fixedDate
    )

    #expect(result.importedTrackCount == 1)
    #expect(FileManager.default.fileExists(atPath: result.crateFileURL.path))
    #expect(!FileManager.default.fileExists(atPath: incomingFile.path))
}

@Test func createNamedCrateUsesExactNameWithoutDate() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let imported = env.destinationRoot.appendingPathComponent("Named Song.mp3")
    try Data("named".utf8).write(to: imported)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try AddMusicImportService.createNamedCrate(
        forAudioFiles: [imported],
        crateName: "Weekend Set",
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory
    )

    #expect(result.crateName == "Weekend Set")
    #expect(FileManager.default.fileExists(atPath: result.crateFileURL.path))
    #expect(result.crateFileURL.lastPathComponent == "Weekend Set.crate")
}

@Test func createNamedCrateAppendsSuffixWhenNameExists() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let imported = env.destinationRoot.appendingPathComponent("Named Song.mp3")
    try Data("named".utf8).write(to: imported)

    let existingCrateURL = env.subcratesDirectory.appendingPathComponent("Weekend Set").appendingPathExtension("crate")
    try AtomicFileWriter.write(Data(), to: existingCrateURL)

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let result = try AddMusicImportService.createNamedCrate(
        forAudioFiles: [imported],
        crateName: "Weekend Set",
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory
    )

    #expect(result.crateName == "Weekend Set (2)")
    #expect(result.crateFileURL.lastPathComponent == "Weekend Set (2).crate")
}

@Test func assignAudioFilesUpdatesCentralCrateAndCreatesSecondaryCrate() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let existingTrack = env.destinationRoot.appendingPathComponent("Existing Song.mp3")
    let importedTrack = env.destinationRoot.appendingPathComponent("Imported Song.mp3")
    try Data("existing".utf8).write(to: existingTrack)
    try Data("imported".utf8).write(to: importedTrack)

    let centralCrateURL = env.subcratesDirectory.appendingPathComponent("All Music").appendingPathExtension("crate")
    let existingStoredPath = SeratoLibraryLocator.seratoStoredPath(for: existingTrack, rootDirectory: rootDirectory)
    let centralData = SeratoCrateWriter.makeCrateData(trackPaths: [existingStoredPath])
    try AtomicFileWriter.write(centralData, to: centralCrateURL)

    let centralCrate = try SeratoCrateParser.parseCrate(at: centralCrateURL)

    let results = try AddMusicImportService.assignAudioFiles(
        [importedTrack],
        assignments: [
            .existing(centralCrate),
            .named("Fresh Finds")
        ],
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory
    )

    #expect(results.count == 2)

    let updatedCentralCrate = try SeratoCrateParser.parseCrate(at: centralCrateURL)
    let freshFindsURL = env.subcratesDirectory.appendingPathComponent("Fresh Finds").appendingPathExtension("crate")
    let freshFindsCrate = try SeratoCrateParser.parseCrate(at: freshFindsURL)
    let importedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: importedTrack, rootDirectory: rootDirectory)

    #expect(Set(updatedCentralCrate.trackPaths) == Set([existingStoredPath, importedStoredPath]))
    #expect(freshFindsCrate.trackPaths == [importedStoredPath])
}

@Test func assignAudioFilesSkipsDuplicateExistingCrateAssignments() throws {
    let env = try makeScratchImportEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory, homeDirectory: env.tempRoot)

    let importedTrack = env.destinationRoot.appendingPathComponent("Imported Song.mp3")
    try Data("imported".utf8).write(to: importedTrack)

    let centralCrateURL = env.subcratesDirectory.appendingPathComponent("All Music").appendingPathExtension("crate")
    try AtomicFileWriter.write(Data(), to: centralCrateURL)

    let centralCrate = try SeratoCrateParser.parseCrate(at: centralCrateURL)

    let results = try AddMusicImportService.assignAudioFiles(
        [importedTrack],
        assignments: [
            .existing(centralCrate),
            .existing(centralCrate)
        ],
        subcratesDirectory: env.subcratesDirectory,
        rootDirectory: rootDirectory
    )

    #expect(results.count == 1)
    #expect(results.first?.crateName == "All Music")
}