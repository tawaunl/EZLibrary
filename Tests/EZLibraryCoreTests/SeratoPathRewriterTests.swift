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

@Suite(.serialized)
struct SeratoPathRewriterTests {

private func makeScratchDatabaseCopy() throws -> URL {
    let fixture = Bundle.module
        .url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
        .appendingPathComponent("database V2")
    let scratchDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("serato-path-rewriter-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    let scratchFile = scratchDir.appendingPathComponent("database V2")
    try FileManager.default.copyItem(at: fixture, to: scratchFile)
    return scratchFile
}

@Test func rewritePathSucceedsAndPersistsToDisk() throws {
    let scratchFile = try makeScratchDatabaseCopy()
    defer { try? FileManager.default.removeItem(at: scratchFile.deletingLastPathComponent()) }

    TestBackupDirectory.use()
    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    let rootDirectory = URL(fileURLWithPath: "/Volumes/Crucial X10")
    let tracks = try SeratoDatabaseParser.parseTracks(at: scratchFile, rootDirectory: rootDirectory)
    let target = try #require(tracks.first)
    let newPath = target.seratoStoredPath + ".RENAMED"

    let didRewrite = try SeratoPathRewriter.rewritePath(target.seratoStoredPath, to: newPath, in: scratchFile)
    #expect(didRewrite)

    let reparsed = try SeratoDatabaseParser.parseTracks(at: scratchFile, rootDirectory: rootDirectory)
    #expect(reparsed.contains { $0.seratoStoredPath == newPath })
}

@Test func rewritePathRefusesWhileSeratoIsRunning() throws {
    let scratchFile = try makeScratchDatabaseCopy()
    defer { try? FileManager.default.removeItem(at: scratchFile.deletingLastPathComponent()) }

    TestSeratoEnvironment.withSeratoRunning {
        #expect(throws: SeratoPathRewriter.RewriteError.seratoIsRunning) {
            try SeratoPathRewriter.rewritePath("Music/anything.mp3", to: "Music/other.mp3", in: scratchFile)
        }
    }
}

@Test func rewritePathThrowsWhenOldPathNotFound() throws {
    let scratchFile = try makeScratchDatabaseCopy()
    defer { try? FileManager.default.removeItem(at: scratchFile.deletingLastPathComponent()) }

    TestBackupDirectory.use()
    TestSeratoEnvironment.pretendSeratoIsClosed()
    defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

    #expect(throws: SeratoPathRewriter.RewriteError.trackNotFound) {
        try SeratoPathRewriter.rewritePath("Music/does-not-exist.mp3", to: "Music/other.mp3", in: scratchFile)
    }
}

}
