// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation
import Testing
@testable import EZLibraryCore

/// These flip the global "is Serato running" override, so they run one at a
/// time rather than concurrently with each other.
@Suite(.serialized) struct SeratoRunningGuardTests {
    init() { TestBackupDirectory.use() }

    /// Every service that mutates the Serato library must refuse while Serato
    /// is running: Serato rewrites its library and crates from memory on quit,
    /// which silently reverts anything written underneath it.
    @Test func syncRefusesWhileSeratoIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serato-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("database V2")
        try Data().write(to: database)
        let file = directory.appendingPathComponent("Song.mp3")
        try Data("a".utf8).write(to: file)

        SeratoProcessGuard.isRunningOverride = true
        defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

        await #expect(throws: LibraryFolderSyncService.SyncError.self) {
            try await LibraryFolderSyncService.syncAudioFiles(
                [file], databaseFileURL: database, rootDirectory: directory
            )
        }
    }

    @Test func tagRefreshRefusesWhileSeratoIsRunning() throws {
        let plan = LibraryTagRefreshService.Plan(
            changes: [
                LibraryTagRefreshService.Change(
                    track: Track(seratoStoredPath: "Music/a.mp3", fileURL: URL(fileURLWithPath: "/tmp/a.mp3")),
                    metadata: SeratoTrackMetadataUpdate(
                        title: "T", artist: "A", album: "", genre: "",
                        comment: "", key: "", bpm: nil, year: nil
                    ),
                    fields: [.init(field: "Title", before: "x", after: "T")]
                )
            ],
            missingFiles: [], untaggedFiles: [], unchangedCount: 0
        )

        SeratoProcessGuard.isRunningOverride = true
        defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

        #expect(throws: LibraryTagRefreshService.RefreshError.self) {
            try LibraryTagRefreshService.apply(
                plan, databaseFileURL: URL(fileURLWithPath: "/tmp/database V2")
            )
        }
    }

    /// Add Music writes crate files directly rather than through
    /// `SeratoCrateEditor`, so it needs the guard in its own right.
    @Test func creatingACrateRefusesWhileSeratoIsRunning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serato-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Song.mp3")
        try Data("a".utf8).write(to: file)

        SeratoProcessGuard.isRunningOverride = true
        defer { TestSeratoEnvironment.pretendSeratoIsClosed() }

        #expect(throws: AddMusicImportService.ImportError.self) {
            _ = try AddMusicImportService.createNamedCrate(
                forAudioFiles: [file],
                crateName: "Test",
                subcratesDirectory: directory,
                rootDirectory: directory
            )
        }
    }

    /// The same operations succeed once Serato is gone, so the guard is what
    /// blocks them rather than something else in the setup.
    @Test func syncSucceedsWhenSeratoIsNotRunning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serato-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("database V2")
        try Data().write(to: database)
        let file = directory.appendingPathComponent("Song.mp3")
        try Data("a".utf8).write(to: file)

        TestSeratoEnvironment.pretendSeratoIsClosed()

        let result = try await LibraryFolderSyncService.syncAudioFiles(
            [file], databaseFileURL: database, rootDirectory: directory
        )
        #expect(result.insertedTracks == 1)
    }

    /// The message has to name the fix; "error 0" is what sent a user hunting.
    @Test func guardErrorsExplainThatSeratoMustQuit() {
        let messages: [String?] = [
            LibraryFolderSyncService.SyncError.seratoIsRunning.errorDescription,
            LibraryTagRefreshService.RefreshError.seratoIsRunning.errorDescription,
            AddMusicImportService.ImportError.seratoIsRunning.errorDescription,
            SeratoCrateEditor.EditError.seratoIsRunning.errorDescription
        ]

        for message in messages {
            #expect(message?.contains("Serato") == true)
            #expect(message?.lowercased().contains("quit") == true)
        }
    }
}
