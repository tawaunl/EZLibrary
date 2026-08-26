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
struct CrateRenameServiceTests {

    private struct Env {
        let library: URL
        let subcrates: URL
        let smartCrates: URL
    }

    private func makeLibrary() throws -> Env {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-rename-\(UUID().uuidString)", isDirectory: true)
        let subcrates = SeratoLibraryLocator.subcratesDirectory(in: library)
        let smartCrates = SeratoLibraryLocator.smartCratesDirectory(in: library)
        try FileManager.default.createDirectory(at: subcrates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: smartCrates, withIntermediateDirectories: true)
        TestBackupDirectory.use()
        return Env(library: library, subcrates: subcrates, smartCrates: smartCrates)
    }

    private func writeCrate(at url: URL, tracks: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SeratoCrateWriter.makeCrateData(trackPaths: tracks).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func fileBaseName(_ components: [String]) -> String {
        Crate.fileBaseName(forPathComponents: components)
    }

    // MARK: - Leaf rename

    @Test func renamesFlatCrateFileAndKeepsTracks() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let original = env.subcrates.appendingPathComponent("House.crate")
        try writeCrate(at: original, tracks: ["Music/a.mp3", "Music/b.mp3"])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["House"], to: "Deep House", libraryDirectory: env.library)

        #expect(moved == 1)
        #expect(!exists(original))
        let renamed = env.subcrates.appendingPathComponent("Deep House.crate")
        #expect(exists(renamed))
        let tracks = SeratoCrateParser.trackPaths(from: try Data(contentsOf: renamed))
        #expect(tracks == ["Music/a.mp3", "Music/b.mp3"])
    }

    // MARK: - Cascading rename

    @Test func renamingParentCascadesToFilenameNestedChildren() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let parent = env.subcrates.appendingPathComponent("\(fileBaseName(["ALL GENRES"])).crate")
        let child = env.subcrates.appendingPathComponent("\(fileBaseName(["ALL GENRES", "Disco"])).crate")
        let grandchild = env.subcrates
            .appendingPathComponent("\(fileBaseName(["ALL GENRES", "Disco", "Italo"])).crate")
        try writeCrate(at: parent, tracks: [])
        try writeCrate(at: child, tracks: ["Music/disco.mp3"])
        try writeCrate(at: grandchild, tracks: ["Music/italo.mp3"])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["ALL GENRES"], to: "GENRES", libraryDirectory: env.library)

        #expect(moved == 3)
        #expect(!exists(parent))
        #expect(!exists(child))
        #expect(!exists(grandchild))
        #expect(exists(env.subcrates.appendingPathComponent("\(fileBaseName(["GENRES"])).crate")))
        #expect(exists(env.subcrates.appendingPathComponent("\(fileBaseName(["GENRES", "Disco"])).crate")))
        #expect(exists(env.subcrates
            .appendingPathComponent("\(fileBaseName(["GENRES", "Disco", "Italo"])).crate")))
    }

    @Test func renamingIntermediateSegmentLeavesSiblingsUntouched() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let target = env.subcrates.appendingPathComponent("\(fileBaseName(["ALL GENRES", "Disco"])).crate")
        let sibling = env.subcrates.appendingPathComponent("\(fileBaseName(["ALL GENRES", "House"])).crate")
        try writeCrate(at: target, tracks: [])
        try writeCrate(at: sibling, tracks: [])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["ALL GENRES", "Disco"], to: "Nu-Disco", libraryDirectory: env.library)

        #expect(moved == 1)
        #expect(exists(env.subcrates.appendingPathComponent("\(fileBaseName(["ALL GENRES", "Nu-Disco"])).crate")))
        #expect(exists(sibling))
        #expect(!exists(target))
    }

    // MARK: - Smart crates

    @Test func renamesSmartCrateFile() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let original = env.smartCrates.appendingPathComponent("Recent.scrate")
        try writeCrate(at: original, tracks: ["Music/a.mp3"])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["Recent"], to: "Fresh", libraryDirectory: env.library)

        #expect(moved == 1)
        #expect(!exists(original))
        #expect(exists(env.smartCrates.appendingPathComponent("Fresh.scrate")))
    }

    // MARK: - Real-subdirectory nesting

    @Test func renamingDirectoryNestedCrateMovesFileAndPrunesEmptyFolder() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let folder = env.subcrates.appendingPathComponent("Serato Stems", isDirectory: true)
        let original = folder.appendingPathComponent("Stems.crate")
        try writeCrate(at: original, tracks: ["Music/stem.mp3"])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["Serato Stems"], to: "Stem Kits", libraryDirectory: env.library)

        #expect(moved == 1)
        #expect(!exists(original))
        #expect(!exists(folder))
        let renamedFolder = env.subcrates.appendingPathComponent("Stem Kits", isDirectory: true)
        #expect(exists(renamedFolder.appendingPathComponent("Stems.crate")))
    }

    // MARK: - Case-only rename

    @Test func renamesToCaseVariantOfSameName() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let original = env.subcrates.appendingPathComponent("house.crate")
        try writeCrate(at: original, tracks: ["Music/a.mp3"])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["house"], to: "House", libraryDirectory: env.library)

        #expect(moved == 1)
        let renamed = env.subcrates.appendingPathComponent("House.crate")
        #expect(exists(renamed))
        let tracks = SeratoCrateParser.trackPaths(from: try Data(contentsOf: renamed))
        #expect(tracks == ["Music/a.mp3"])
    }

    // MARK: - No-op

    @Test func renamingToSameNameIsANoOp() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let original = env.subcrates.appendingPathComponent("House.crate")
        try writeCrate(at: original, tracks: [])

        let moved = try CrateRenameService.rename(
            crateAtPath: ["House"], to: "House", libraryDirectory: env.library)

        #expect(moved == 0)
        #expect(exists(original))
    }

    // MARK: - Failures

    @Test func rejectsCollisionWithExistingSibling() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        let source = env.subcrates.appendingPathComponent("House.crate")
        let occupied = env.subcrates.appendingPathComponent("Techno.crate")
        try writeCrate(at: source, tracks: ["Music/a.mp3"])
        try writeCrate(at: occupied, tracks: ["Music/keep.mp3"])

        #expect(throws: CrateRenameService.RenameError.self) {
            try CrateRenameService.rename(
                crateAtPath: ["House"], to: "Techno", libraryDirectory: env.library)
        }
        // Both files stay put and the occupant is untouched.
        #expect(exists(source))
        #expect(SeratoCrateParser.trackPaths(from: try Data(contentsOf: occupied)) == ["Music/keep.mp3"])
    }

    @Test func rejectsEmptyName() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }
        try writeCrate(at: env.subcrates.appendingPathComponent("House.crate"), tracks: [])

        #expect(throws: CrateRenameService.RenameError.self) {
            try CrateRenameService.rename(
                crateAtPath: ["House"], to: "   ", libraryDirectory: env.library)
        }
    }

    @Test func rejectsNameWithNestingDelimiter() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }
        try writeCrate(at: env.subcrates.appendingPathComponent("House.crate"), tracks: [])

        #expect(throws: CrateRenameService.RenameError.self) {
            try CrateRenameService.rename(
                crateAtPath: ["House"], to: "A\(Crate.nestingDelimiter)B", libraryDirectory: env.library)
        }
    }

    @Test func rejectsNameWithPathSeparator() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }
        try writeCrate(at: env.subcrates.appendingPathComponent("House.crate"), tracks: [])

        #expect(throws: CrateRenameService.RenameError.self) {
            try CrateRenameService.rename(
                crateAtPath: ["House"], to: "A/B", libraryDirectory: env.library)
        }
    }

    @Test func throwsWhenCrateDoesNotExist() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }

        #expect(throws: CrateRenameService.RenameError.self) {
            try CrateRenameService.rename(
                crateAtPath: ["Nope"], to: "Something", libraryDirectory: env.library)
        }
    }

    @Test func refusesWhenSeratoIsRunning() throws {
        let env = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: env.library) }
        let original = env.subcrates.appendingPathComponent("House.crate")
        try writeCrate(at: original, tracks: [])

        try TestSeratoEnvironment.withSeratoRunning {
            #expect(throws: CrateRenameService.RenameError.self) {
                try CrateRenameService.rename(
                    crateAtPath: ["House"], to: "Deep", libraryDirectory: env.library)
            }
        }
        #expect(exists(original))
    }
}
