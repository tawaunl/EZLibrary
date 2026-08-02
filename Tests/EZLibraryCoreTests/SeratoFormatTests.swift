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

/// Reads every top-level chunk tag in order, so a rewrite can be checked for
/// having preserved a smart crate's rule payload rather than regenerating it.
private func topLevelChunkTags(of data: Data) -> [String] {
    SeratoChunkCodec.readChunks(from: data).map(\.tag)
}

@Test func rewritingSmartCrateKeepsItsRulesIntact() throws {
    let crateURL = fixture("SmartCrates/ALL GENRES\u{226B}\u{226B}House.scrate")
    let original = try Data(contentsOf: crateURL)
    let paths = SeratoCrateParser.trackPaths(from: original)
    let target = try #require(paths.first)

    let rewritten = SeratoCrateWriter.rewritingTrackPaths(
        [target: "Users/tawaun/Music/All Music/Renamed.mp3"], in: original
    )

    #expect(rewritten.rewrittenCount == 1)

    let newPaths = SeratoCrateParser.trackPaths(from: rewritten.data)
    #expect(newPaths.count == paths.count)
    #expect(newPaths.contains("Users/tawaun/Music/All Music/Renamed.mp3"))
    #expect(!newPaths.contains(target))

    // A smart crate's rules (`rart`/`rlut`/`rurt`) and column layout live
    // beside its member list. Regenerating from paths alone would drop them,
    // which is why these files used to be skipped entirely — and skipping
    // them is what left Serato re-importing the pre-rename path.
    #expect(topLevelChunkTags(of: rewritten.data) == topLevelChunkTags(of: original))
}

@Test func metadataRenameRewritesSmartCratePathsToo() throws {
    let env = try makeMetadataRenameEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    TestBackupDirectory.use()
    TestSeratoEnvironment.pretendSeratoIsClosed()

    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let smartCrateURL = env.libraryDirectory
        .appendingPathComponent("SmartCrates/ALL GENRES\u{226B}\u{226B}House.scrate")
    // The sample smart crates were captured from a different user's library
    // than the sample `database V2`, so point one of their entries at a track
    // this database actually has. (Seeded with the primitive covered by
    // `rewritingSmartCrateKeepsItsRulesIntact`.)
    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)
    let originalSmartCrate = try Data(contentsOf: smartCrateURL)
    let seedPath = try #require(SeratoCrateParser.trackPaths(from: originalSmartCrate).first)
    let seeded = SeratoCrateWriter.rewritingTrackPaths(
        [seedPath: target.seratoStoredPath], in: originalSmartCrate)
    #expect(seeded.rewrittenCount == 1)
    try seeded.data.write(to: smartCrateURL)

    try FileManager.default.createDirectory(
        at: target.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: target.fileURL)

    try SeratoTrackMetadataEditor.update(
        track: target,
        metadata: SeratoTrackMetadataUpdate(
            title: "Smart", artist: "Crate", album: "", genre: "",
            comment: target.comment, key: target.key ?? "", bpm: target.bpm, year: nil),
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true,
        filenameTemplate: "{artist}-{title}"
    )

    let renamed = target.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Crate-Smart.\(target.fileURL.pathExtension)")
    let expectedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: renamed, rootDirectory: rootDirectory)

    // Serato re-adds a renamed track as a second, missing entry when any
    // crate still names the old path — smart crates included.
    let updated = SeratoCrateParser.trackPaths(from: try Data(contentsOf: smartCrateURL))
    #expect(updated.contains(expectedStoredPath))
    #expect(!updated.contains(target.seratoStoredPath))
}

@Test func crateWriterRoundTripsTrackPaths() {
    let paths = ["Imported/Track One.mp3", "Imported/Track Two.mp3"]
    let data = SeratoCrateWriter.makeCrateData(trackPaths: paths)
    #expect(SeratoCrateParser.trackPaths(from: data) == paths)
}

@Test func metadataRenameRewritesDatabaseAndCratePaths() throws {
    let env = try makeMetadataRenameEnvironment()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

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

    // Default template is {artist}-{title}-{album}-{year}, so genre is not
    // part of the name unless the user's template asks for it.
    let expectedFilename = "ArtistRen-TitleRen-AlbumRen-2026.\(targetTrack.fileURL.pathExtension)"
    let expectedFileURL = targetTrack.fileURL.deletingLastPathComponent().appendingPathComponent(expectedFilename)
    let expectedStoredPath = SeratoLibraryLocator.seratoStoredPath(for: expectedFileURL, rootDirectory: rootDirectory)

    let reparsedTracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    #expect(reparsedTracks.contains(where: { $0.seratoStoredPath == expectedStoredPath }))
    #expect(!reparsedTracks.contains(where: { $0.seratoStoredPath == oldStoredPath }))

    let reparsedCrate = try SeratoCrateParser.parseCrate(at: crateURL)
    #expect(reparsedCrate.trackPaths.contains(expectedStoredPath))
    #expect(!reparsedCrate.trackPaths.contains(oldStoredPath))
}

/// Sets up a renameable track and returns it alongside the environment.
private func makeRenameTarget() throws -> (
    env: (tempRoot: URL, libraryDirectory: URL, databaseFile: URL),
    track: Track
) {
    let env = try makeMetadataRenameEnvironment()
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let tracks = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)

    try FileManager.default.createDirectory(
        at: target.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("audio".utf8).write(to: target.fileURL)
    return (env, target)
}

private func renameMetadata() -> SeratoTrackMetadataUpdate {
    SeratoTrackMetadataUpdate(
        title: "Latch",
        artist: "Disclosure",
        album: "Settle",
        genre: "House",
        comment: "",
        key: "Ab",
        bpm: 122,
        year: 2012
    )
}

@Test func renameUsesTheConfiguredFilenameTemplate() throws {
    let (env, target) = try makeRenameTarget()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    try SeratoTrackMetadataEditor.update(
        track: target,
        metadata: renameMetadata(),
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true,
        filenameTemplate: "{title} - {artist} [{bpm}] ({key})"
    )

    let expected = target.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Latch - Disclosure [122] (Ab).\(target.fileURL.pathExtension)")
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(!FileManager.default.fileExists(atPath: target.fileURL.path))
}

@Test func renameDropsTokensThatHaveNoValueWithoutLeavingSeparators() throws {
    let (env, target) = try makeRenameTarget()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    var metadata = renameMetadata()
    metadata.album = ""
    metadata.year = nil

    try SeratoTrackMetadataEditor.update(
        track: target,
        metadata: metadata,
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true,
        filenameTemplate: "{artist}-{album}-{title}-{year}"
    )

    let expected = target.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Disclosure-Latch.\(target.fileURL.pathExtension)")
    #expect(FileManager.default.fileExists(atPath: expected.path))
}

@Test func resavingUnchangedMetadataDoesNotChurnTheFilename() throws {
    let (env, target) = try makeRenameTarget()
    defer { try? FileManager.default.removeItem(at: env.tempRoot) }

    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    let template = "{artist}-{title}"
    let directory = target.fileURL.deletingLastPathComponent()
    let expected = directory.appendingPathComponent("Disclosure-Latch.\(target.fileURL.pathExtension)")

    try SeratoTrackMetadataEditor.update(
        track: target,
        metadata: renameMetadata(),
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true,
        filenameTemplate: template
    )
    #expect(FileManager.default.fileExists(atPath: expected.path))

    // Saving again with the same values must be a no-op. Treating the file
    // as a collision with itself used to walk it to "… (2)", then "… (3)".
    let rootDirectory = SeratoLibraryLocator.rootDirectory(for: env.libraryDirectory)
    let reparsed = try SeratoDatabaseParser.parseTracks(at: env.databaseFile, rootDirectory: rootDirectory)
    let renamedTrack = try #require(reparsed.first { $0.fileURL.lastPathComponent == expected.lastPathComponent })

    try SeratoTrackMetadataEditor.update(
        track: renamedTrack,
        metadata: renameMetadata(),
        databaseFileURL: env.databaseFile,
        rewriteFilenameFromMetadata: true,
        filenameTemplate: template
    )

    #expect(FileManager.default.fileExists(atPath: expected.path))
    let names = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("Disclosure-Latch") }
    #expect(names == [expected.lastPathComponent])
}
