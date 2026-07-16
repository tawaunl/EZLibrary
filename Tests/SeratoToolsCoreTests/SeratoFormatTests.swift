import Testing
import Foundation
@testable import SeratoToolsCore

private func fixture(_ path: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent(path)
}

private func makeMetadataRenameEnvironment() throws -> (tempRoot: URL, libraryDirectory: URL, databaseFile: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-metadata-rename-test-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = tempRoot.appendingPathComponent("_Serato_", isDirectory: true)
    let sourceFixtureRoot = Bundle.module.url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!

    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceFixtureRoot, to: libraryDirectory)

    return (
        tempRoot: tempRoot,
        libraryDirectory: libraryDirectory,
        databaseFile: libraryDirectory.appendingPathComponent("database V2")
    )
}

@Test func parsesRealDatabaseFixture() throws {
    let databaseFile = fixture("database V2")
    let rootDirectory = URL(fileURLWithPath: "/Volumes/Crucial X10")
    let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
    #expect(!tracks.isEmpty)
    #expect(tracks.allSatisfy { !$0.seratoStoredPath.isEmpty })
}

@Test func parsesRealCrateFixtureAndMatchesDatabase() throws {
    let databaseFile = fixture("database V2")
    let rootDirectory = URL(fileURLWithPath: "/Volumes/Crucial X10")
    let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
    let trackPaths = Set(tracks.map(\.seratoStoredPath))

    let crate = try SeratoCrateParser.parseCrate(at: fixture("Subcrates/Mike's Party.crate"))
    #expect(crate.name == "Mike's Party")
    #expect(!crate.trackPaths.isEmpty)
    #expect(crate.trackPaths.allSatisfy(trackPaths.contains))
}

@Test func parsesNestedCrateDelimiter() {
    let components = Crate.pathComponents(forCrateFileNamed: "ALL GENRES\u{226B}\u{226B}Disco")
    #expect(components == ["ALL GENRES", "Disco"])
    #expect(Crate.fileBaseName(forPathComponents: components) == "ALL GENRES\u{226B}\u{226B}Disco")
}

@Test func rootDirectoryIsVolumeMountPointForExternalLibrary() {
    let library = URL(fileURLWithPath: "/Volumes/Crucial X10/_Serato_")
    #expect(SeratoLibraryLocator.rootDirectory(for: library).path == "/Volumes/Crucial X10")
}

@Test func rootDirectoryIsFilesystemRootForHomeVolumeLibrary() {
    let home = URL(fileURLWithPath: "/Users/example")
    let library = home.appendingPathComponent("Music/_Serato_")
    #expect(SeratoLibraryLocator.rootDirectory(for: library, homeDirectory: home).path == "/")
}

@Test func databaseWriterRewritesOnlyTheTargetTrackPath() throws {
    let databaseFile = fixture("database V2")
    let rootDirectory = URL(fileURLWithPath: "/Volumes/Crucial X10")
    let originalData = try Data(contentsOf: databaseFile)
    let tracks = SeratoDatabaseParser.parseTracks(from: originalData, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)
    let newPath = target.seratoStoredPath + ".RENAMED"

    let (rewritten, didRewrite) = SeratoDatabaseWriter.rewritingPath(
        target.seratoStoredPath, to: newPath, in: originalData
    )
    #expect(didRewrite)

    let reparsed = SeratoDatabaseParser.parseTracks(from: rewritten, rootDirectory: rootDirectory)
    #expect(reparsed.count == tracks.count)
    #expect(reparsed.contains { $0.seratoStoredPath == newPath })
    #expect(!reparsed.contains { $0.seratoStoredPath == target.seratoStoredPath })

    // Every other track's fields must be untouched by the rewrite.
    let untouchedOriginal = tracks.filter { $0.id != target.id }
    let untouchedRewritten = reparsed.filter { $0.seratoStoredPath != newPath }
    for (original, rewrittenTrack) in zip(untouchedOriginal, untouchedRewritten) {
        #expect(original.title == rewrittenTrack.title)
        #expect(original.artist == rewrittenTrack.artist)
        #expect(original.seratoStoredPath == rewrittenTrack.seratoStoredPath)
    }
}

@Test func crateWriterRoundTripsTrackPaths() {
    let paths = ["Imported/Track One.mp3", "Imported/Track Two.mp3"]
    let data = SeratoCrateWriter.makeCrateData(trackPaths: paths)
    #expect(SeratoCrateParser.trackPaths(from: data) == paths)
}

@Test func metadataRenameRewritesDatabaseAndCratePaths() throws {
    let env = try makeMetadataRenameEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    SeratoProcessGuard.isRunningOverride = false
    defer { SeratoProcessGuard.isRunningOverride = nil }

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let crateURL = env.libraryDirectory.appendingPathComponent("Subcrates/Mike's Party.crate")
    let crate = try SeratoCrateParser.parseCrate(at: crateURL)
    let oldStoredPath = try #require(crate.trackPaths.first)

    let originalTracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let targetTrack = try #require(originalTracks.first(where: { $0.seratoStoredPath == oldStoredPath }))

    try FileManager.default.createDirectory(
        at: targetTrack.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("audio".utf8).write(to: targetTrack.fileURL)

    let metadata = SeratoTrackMetadataUpdate(
        title: "TitleRen",
        artist: "ArtistRen",
        album: "AlbumRen",
        genre: "GenreRen",
        comment: targetTrack.comment,
        key: targetTrack.key ?? "",
        bpm: targetTrack.bpm,
        year: 2026
    )

    try SeratoTrackMetadataEditor.update(
        track: targetTrack,
        metadata: metadata,
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true
    )

    let expectedFilename = "ArtistRen-TitleRen-AlbumRen-2026-GenreRen.\(targetTrack.fileURL.pathExtension)"
    let expectedFileURL = targetTrack.fileURL.deletingLastPathComponent().appendingPathComponent(expectedFilename)
    let expectedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: expectedFileURL, rootDirectory: rootDirectory)

    let reparsedTracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    #expect(reparsedTracks.contains(where: { $0.seratoStoredPath == expectedStoredPath }))
    #expect(!reparsedTracks.contains(where: { $0.seratoStoredPath == oldStoredPath }))

    let reparsedCrate = try SeratoCrateParser.parseCrate(at: crateURL)
    #expect(reparsedCrate.trackPaths.contains(expectedStoredPath))
    #expect(!reparsedCrate.trackPaths.contains(oldStoredPath))
}
