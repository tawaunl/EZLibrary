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
struct CrateMembershipServiceTests {

    private struct Env {
        let root: URL
        let crate: Crate
    }

    private func makeCrate(paths: [String], name: String = "Bangers") throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-membership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TestBackupDirectory.use()

        let fileURL = root.appendingPathComponent("\(name).crate")
        try SeratoCrateWriter.makeCrateData(trackPaths: paths).write(to: fileURL)

        return Env(
            root: root,
            crate: Crate(pathComponents: [name], trackPaths: paths, fileURL: fileURL)
        )
    }

    private func pathsOnDisk(_ crate: Crate) throws -> [String] {
        SeratoCrateParser.trackPaths(from: try Data(contentsOf: crate.fileURL!))
    }

    // MARK: - Adding

    @Test func addAppendsNewTracks() throws {
        let env = try makeCrate(paths: ["Music/a.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.add(
            storedPaths: ["Music/b.mp3", "Music/c.mp3"], to: env.crate)

        #expect(change.changedCount == 2)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3", "Music/b.mp3", "Music/c.mp3"])
    }

    @Test func addSkipsTracksTheCrateAlreadyHas() throws {
        let env = try makeCrate(paths: ["Music/a.mp3", "Music/b.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.add(
            storedPaths: ["Music/b.mp3", "Music/c.mp3"], to: env.crate)

        #expect(change.changedCount == 1)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3", "Music/b.mp3", "Music/c.mp3"])
    }

    @Test func addIsANoOpWhenEverythingIsAlreadyThere() throws {
        let env = try makeCrate(paths: ["Music/a.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.add(storedPaths: ["Music/a.mp3"], to: env.crate)

        #expect(change.changedCount == 0)
        #expect(!change.didChange)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3"])
    }

    @Test func addDeduplicatesWithinTheRequestItself() throws {
        let env = try makeCrate(paths: [])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.add(
            storedPaths: ["Music/a.mp3", "Music/a.mp3"], to: env.crate)

        #expect(change.changedCount == 1)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3"])
    }

    /// Membership is compared the way the rest of the app compares paths, so a
    /// track already filed under a differently-spelled path isn't re-added.
    @Test func addMatchesExistingEntriesRegardlessOfSpelling() throws {
        let env = try makeCrate(paths: ["/Music/A.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.add(storedPaths: ["Music/a.mp3"], to: env.crate)

        #expect(change.changedCount == 0)
    }

    // MARK: - Removing

    @Test func removeDropsOnlyTheNamedTracks() throws {
        let env = try makeCrate(paths: ["Music/a.mp3", "Music/b.mp3", "Music/c.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.remove(
            storedPaths: ["Music/b.mp3"], from: env.crate)

        #expect(change.changedCount == 1)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3", "Music/c.mp3"])
    }

    @Test func removeHandlesTracksTheCrateDoesNotHave() throws {
        let env = try makeCrate(paths: ["Music/a.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.remove(
            storedPaths: ["Music/zzz.mp3"], from: env.crate)

        #expect(change.changedCount == 0)
        #expect(try pathsOnDisk(env.crate) == ["Music/a.mp3"])
    }

    @Test func removeMatchesRegardlessOfSpelling() throws {
        let env = try makeCrate(paths: ["Music\\Sub\\A.mp3", "Music/b.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.remove(
            storedPaths: ["music/sub/a.mp3"], from: env.crate)

        #expect(change.changedCount == 1)
        #expect(try pathsOnDisk(env.crate) == ["Music/b.mp3"])
    }

    @Test func removeCanEmptyTheCrate() throws {
        let env = try makeCrate(paths: ["Music/a.mp3", "Music/b.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let change = try CrateMembershipService.remove(
            storedPaths: ["Music/a.mp3", "Music/b.mp3"], from: env.crate)

        #expect(change.changedCount == 2)
        #expect(try pathsOnDisk(env.crate).isEmpty)
    }

    // MARK: - Staleness and errors

    /// The crate the UI holds can be minutes old. Writing it back verbatim
    /// would undo anything changed since, so both operations re-read first.
    @Test func writesAgainstTheCrateOnDiskNotTheStaleCopy() throws {
        let env = try makeCrate(paths: ["Music/a.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        // Something else files another track while the UI still holds the old copy.
        try SeratoCrateWriter.makeCrateData(trackPaths: ["Music/a.mp3", "Music/added-elsewhere.mp3"])
            .write(to: env.crate.fileURL!)

        _ = try CrateMembershipService.add(storedPaths: ["Music/new.mp3"], to: env.crate)

        #expect(try pathsOnDisk(env.crate)
            == ["Music/a.mp3", "Music/added-elsewhere.mp3", "Music/new.mp3"])
    }

    @Test func removeAlsoRespectsConcurrentAdditions() throws {
        let env = try makeCrate(paths: ["Music/a.mp3"])
        defer { try? FileManager.default.removeItem(at: env.root) }

        try SeratoCrateWriter.makeCrateData(trackPaths: ["Music/a.mp3", "Music/added-elsewhere.mp3"])
            .write(to: env.crate.fileURL!)

        _ = try CrateMembershipService.remove(storedPaths: ["Music/a.mp3"], from: env.crate)

        #expect(try pathsOnDisk(env.crate) == ["Music/added-elsewhere.mp3"])
    }

    @Test func aCrateWithNoFileIsAReadableError() {
        let crate = Crate(pathComponents: ["Ghost"], trackPaths: [], fileURL: nil)

        #expect(throws: CrateMembershipService.MembershipError.self) {
            try CrateMembershipService.add(storedPaths: ["Music/a.mp3"], to: crate)
        }
        #expect(throws: CrateMembershipService.MembershipError.self) {
            try CrateMembershipService.remove(storedPaths: ["Music/a.mp3"], from: crate)
        }
    }
}
