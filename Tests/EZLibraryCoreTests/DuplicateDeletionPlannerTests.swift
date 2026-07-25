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

private let sandbox = FileManager.default.temporaryDirectory
    .appendingPathComponent("ezlib-deletion-\(UUID().uuidString)")

private func makeFile(_ name: String) -> URL {
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let url = sandbox.appendingPathComponent(name)
    try? Data("audio".utf8).write(to: url)
    return url
}

private func track(_ storedPath: String, fileURL: URL) -> Track {
    Track(seratoStoredPath: storedPath, fileURL: fileURL, title: "T", artist: "A")
}

@Test func seratoRunningBlocksTheWholeDeletion() {
    // The block must be reported before anything is trashed — the crate writer
    // refuses while Serato is open, and it used to refuse after the fact.
    #expect(DuplicateDeletionPlanner.blocker(seratoIsRunning: true) == .seratoIsRunning)
    #expect(DuplicateDeletionPlanner.blocker(seratoIsRunning: false) == nil)
    #expect(DuplicateDeletionPlanner.Blocker.seratoIsRunning.errorDescription?.isEmpty == false)
}

@Test func ordinaryDuplicateFileIsTrashed() {
    let dup = makeFile("dup.mp3")
    let keep = makeFile("keep.mp3")
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let files = DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: [track("Music/dup.mp3", fileURL: dup)],
        survivingTracks: [track("Music/keep.mp3", fileURL: keep)]
    )

    #expect(files.map(\.lastPathComponent) == ["dup.mp3"])
}

@Test func fileStillReferencedByASurvivingEntryIsNeverTrashed() {
    // Two library entries, one file on disk. Trashing it would break the entry
    // the user chose to keep.
    let shared = makeFile("shared.mp3")
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let files = DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: [track("Music/entryA.mp3", fileURL: shared)],
        survivingTracks: [track("Music/entryB.mp3", fileURL: shared)]
    )

    #expect(files.isEmpty)
}

@Test func missingFileIsSkipped() {
    let ghost = sandbox.appendingPathComponent("not-there-\(UUID().uuidString).mp3")

    let files = DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: [track("Music/ghost.mp3", fileURL: ghost)],
        survivingTracks: []
    )

    #expect(files.isEmpty)
}

@Test func oneFileIsNeverTrashedTwice() {
    // Two entries being deleted that point at the same file.
    let shared = makeFile("shared.mp3")
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let files = DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: [
            track("Music/entryA.mp3", fileURL: shared),
            track("Music/entryB.mp3", fileURL: shared)
        ],
        survivingTracks: []
    )

    #expect(files.count == 1)
}

@Test func pathsAreComparedAfterStandardizing() {
    let shared = makeFile("shared.mp3")
    defer { try? FileManager.default.removeItem(at: sandbox) }

    // Same file reached through a non-standard path.
    let indirect = sandbox
        .appendingPathComponent("sub")
        .appendingPathComponent("..")
        .appendingPathComponent("shared.mp3")

    let files = DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: [track("Music/a.mp3", fileURL: indirect)],
        survivingTracks: [track("Music/b.mp3", fileURL: shared)]
    )

    #expect(files.isEmpty)
}

@Test func survivingTracksExcludesEverythingBeingDeleted() {
    let a = track("Music/a.mp3", fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
    let b = track("Music/b.mp3", fileURL: URL(fileURLWithPath: "/tmp/b.mp3"))
    let c = track("Music/c.mp3", fileURL: URL(fileURLWithPath: "/tmp/c.mp3"))

    let surviving = DuplicateDeletionPlanner.survivingTracks(
        in: [a, b, c],
        deletedPaths: ["Music/a.mp3", "Music/c.mp3"]
    )

    #expect(surviving.map(\.seratoStoredPath) == ["Music/b.mp3"])
}

@Test func deletingEverythingLeavesNoSurvivorsButStillTrashesOnce() {
    let one = makeFile("one.mp3")
    let two = makeFile("two.mp3")
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let deleted = [track("Music/one.mp3", fileURL: one), track("Music/two.mp3", fileURL: two)]
    let surviving = DuplicateDeletionPlanner.survivingTracks(
        in: deleted,
        deletedPaths: ["Music/one.mp3", "Music/two.mp3"]
    )

    #expect(surviving.isEmpty)
    #expect(DuplicateDeletionPlanner.filesToTrash(
        deletedTracks: deleted,
        survivingTracks: surviving
    ).count == 2)
}
