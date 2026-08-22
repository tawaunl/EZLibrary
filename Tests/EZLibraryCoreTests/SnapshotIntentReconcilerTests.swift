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

// MARK: - Builders

private func track(
    _ path: String,
    title: String = "Song",
    artist: String = "Artist",
    genre: String = ""
) -> Track {
    Track(
        seratoStoredPath: path,
        fileURL: URL(fileURLWithPath: "/" + path),
        title: title,
        artist: artist,
        genre: genre
    )
}

private func editIntent(
    path: String,
    title: String = "Song",
    artist: String = "Artist",
    field: TrackField,
    old: String?,
    new: String
) -> SnapshotIntent {
    SnapshotIntent(
        baseSnapshotID: UUID(),
        operation: .editTrackField(
            track: TrackReference(storedPath: path, title: title, artist: artist),
            field: field,
            oldValue: old,
            newValue: new
        )
    )
}

private func queue(
    _ intents: [SnapshotIntent],
    device: String = "Test iPhone",
    id: UUID = UUID(),
    at: Date = Date()
) -> SnapshotIntentQueue {
    SnapshotIntentQueue(
        deviceID: id,
        deviceName: device,
        generatedAt: at,
        baseSnapshotID: UUID(),
        intents: intents
    )
}

// MARK: - Queue file format

@Suite struct SnapshotIntentQueueTests {

    @Test func fileNameIsStableAndLowercased() {
        let id = UUID()
        let q = queue([], id: id)
        #expect(q.fileName == "queue-\(id.uuidString.lowercased()).json")
    }

    @Test func recognisesQueueFilesAndRejectsSnapshots() {
        #expect(SnapshotIntentQueue.isQueueFileName("queue-abc.json"))
        #expect(!SnapshotIntentQueue.isQueueFileName("snapshot-abc.json"))
        #expect(!SnapshotIntentQueue.isQueueFileName("queue-abc.txt"))
    }

    @Test func codecRoundTrips() throws {
        let original = queue([
            editIntent(path: "Music/a.mp3", field: .genre, old: nil, new: "House"),
            SnapshotIntent(baseSnapshotID: UUID(), operation: .createCrate(name: "New", parentPathComponents: []))
        ])
        let data = try SnapshotIntentQueueCodec.encode(original)
        let decoded = try SnapshotIntentQueueCodec.decode(data)
        #expect(decoded == original)
    }
}

// MARK: - Ingest

@Suite struct SnapshotIntentIngestServiceTests {

    @Test func discoversOnlyQueueFilesOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezlibrary-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = queue(
            [editIntent(path: "a.mp3", field: .genre, old: nil, new: "House")],
            at: Date(timeIntervalSince1970: 1_000)
        )
        let newer = queue(
            [editIntent(path: "b.mp3", field: .genre, old: nil, new: "Techno")],
            at: Date(timeIntervalSince1970: 2_000)
        )
        try SnapshotIntentQueueCodec.encode(newer).write(to: dir.appendingPathComponent(newer.fileName))
        try SnapshotIntentQueueCodec.encode(older).write(to: dir.appendingPathComponent(older.fileName))
        // A snapshot file must be ignored.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("snapshot-deadbeef.json"))

        let discovered = SnapshotIntentIngestService.discoverQueues(in: dir)
        #expect(discovered.count == 2)
        #expect(discovered.first?.queue.deviceID == older.deviceID)
        #expect(discovered.last?.queue.deviceID == newer.deviceID)
    }
}

// MARK: - Reconciler

@Suite struct SnapshotIntentReconcilerTests {

    @Test func fieldEditResolvesWhenValueUnchanged() {
        let tracks = [track("Music/a.mp3", genre: "")]
        let q = queue([editIntent(path: "Music/a.mp3", field: .genre, old: nil, new: "House")])
        let plan = SnapshotIntentReconciler.plan(queues: [q], tracks: tracks, crates: [])
        #expect(plan.count == 1)
        #expect(plan[0].status == .applicable)
        #expect(plan[0].isApplyable)
    }

    @Test func fieldEditIsRedundantWhenAlreadyMatching() {
        let tracks = [track("Music/a.mp3", genre: "House")]
        let q = queue([editIntent(path: "Music/a.mp3", field: .genre, old: nil, new: "House")])
        let plan = SnapshotIntentReconciler.plan(queues: [q], tracks: tracks, crates: [])
        #expect(plan[0].status == .redundant)
        #expect(!plan[0].isApplyable)
    }

    @Test func fieldEditConflictsWhenMacChangedSince() {
        let tracks = [track("Music/a.mp3", genre: "Techno")]
        let q = queue([editIntent(path: "Music/a.mp3", field: .genre, old: "House", new: "Disco")])
        let plan = SnapshotIntentReconciler.plan(queues: [q], tracks: tracks, crates: [])
        if case .conflict = plan[0].status {} else { Issue.record("expected conflict, got \(plan[0].status)") }
        // A conflict is still applyable — the user may choose to overwrite.
        #expect(plan[0].isApplyable)
    }

    @Test func fieldEditUnresolvedWhenTrackGone() {
        let tracks = [track("Music/a.mp3", title: "Keep", artist: "Me")]
        let q = queue([editIntent(path: "Music/gone.mp3", title: "Missing", artist: "Nobody",
                                  field: .genre, old: nil, new: "House")])
        let plan = SnapshotIntentReconciler.plan(queues: [q], tracks: tracks, crates: [])
        if case .unresolved = plan[0].status {} else { Issue.record("expected unresolved, got \(plan[0].status)") }
        #expect(!plan[0].isApplyable)
    }

    @Test func createCrateApplicableThenRedundant() {
        let existing = Crate(pathComponents: ["Existing"], trackPaths: [])
        let intents = [
            SnapshotIntent(baseSnapshotID: UUID(), operation: .createCrate(name: "Fresh", parentPathComponents: [])),
            SnapshotIntent(baseSnapshotID: UUID(), operation: .createCrate(name: "Existing", parentPathComponents: []))
        ]
        let plan = SnapshotIntentReconciler.plan(queues: [queue(intents)], tracks: [], crates: [existing])
        #expect(plan[0].status == .applicable)
        #expect(plan[1].status == .redundant)
    }

    @Test func deleteCrateRedundantWhenAbsentApplicableWhenPresent() {
        let present = Crate(pathComponents: ["Keep"], trackPaths: [], fileURL: URL(fileURLWithPath: "/tmp/Keep.crate"))
        let intents = [
            SnapshotIntent(baseSnapshotID: UUID(), operation: .deleteCrate(pathComponents: ["Ghost"])),
            SnapshotIntent(baseSnapshotID: UUID(), operation: .deleteCrate(pathComponents: ["Keep"]))
        ]
        let plan = SnapshotIntentReconciler.plan(queues: [queue(intents)], tracks: [], crates: [present])
        #expect(plan[0].status == .redundant)
        #expect(plan[1].status == .applicable)
    }

    @Test func renameCrateConflictsWhenDestinationExists() {
        let a = Crate(pathComponents: ["A"], trackPaths: [], fileURL: URL(fileURLWithPath: "/tmp/A.crate"))
        let b = Crate(pathComponents: ["B"], trackPaths: [], fileURL: URL(fileURLWithPath: "/tmp/B.crate"))
        let intents = [
            SnapshotIntent(baseSnapshotID: UUID(), operation: .renameCrate(pathComponents: ["A"], newName: "B")),
            SnapshotIntent(baseSnapshotID: UUID(), operation: .renameCrate(pathComponents: ["A"], newName: "C"))
        ]
        let plan = SnapshotIntentReconciler.plan(queues: [queue(intents)], tracks: [], crates: [a, b])
        if case .conflict = plan[0].status {} else { Issue.record("expected conflict, got \(plan[0].status)") }
        #expect(plan[1].status == .applicable)
    }
}

// MARK: - Applying intents to a snapshot (portable preview)

@Suite struct SnapshotApplyingIntentsTests {

    @Test func applyingEditsTheNamedField() {
        let snapshot = LibrarySnapshot(
            libraryFingerprint: "fp",
            tracks: [SnapshotTrack(storedPath: "a.mp3", title: "Song", artist: "Artist", genre: "")],
            crates: []
        )
        let intent = editIntent(path: "a.mp3", field: .genre, old: nil, new: "House")
        let result = snapshot.applying([intent])
        #expect(result.tracks.first?.genre == "House")
    }
}
