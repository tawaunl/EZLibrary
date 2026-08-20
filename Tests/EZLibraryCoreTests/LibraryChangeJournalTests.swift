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

private let epoch = Date(timeIntervalSince1970: 1_750_000_000)
private func at(_ offsetHours: Double) -> Date { epoch.addingTimeInterval(offsetHours * 3600) }

@Test func journalReportsUnmovedPathUnchanged() {
    let journal = LibraryChangeJournal()
    #expect(journal.currentPath(for: "Music/Track.mp3") == "Music/Track.mp3")
}

@Test func journalFollowsASingleMove() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "Music/All Music/Track.mp3", to: "Music/Consolidated/Track.mp3"), at: at(1))
    #expect(journal.currentPath(for: "Music/All Music/Track.mp3") == "Music/Consolidated/Track.mp3")
}

@Test func journalFollowsAChainOfMoves() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    journal.record(.trackMoved(from: "b.mp3", to: "c.mp3"), at: at(2))
    #expect(journal.currentPath(for: "a.mp3") == "c.mp3")
}

/// A file consolidated and then moved back must resolve to where it actually
/// is, not to the last destination recorded for it.
@Test func journalResolvesAFileMovedBackToItsOrigin() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    journal.record(.trackMoved(from: "b.mp3", to: "a.mp3"), at: at(2))
    #expect(journal.currentPath(for: "a.mp3") == "a.mp3")
}

@Test func journalIgnoresMovesAtOrBeforeTheSinceDate() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    journal.record(.trackMoved(from: "b.mp3", to: "c.mp3"), at: at(5))
    #expect(journal.currentPath(for: "a.mp3", since: at(3)) == "a.mp3")
    #expect(journal.currentPath(for: "b.mp3", since: at(3)) == "c.mp3")
}

@Test func recordingMovesSkipsUnchangedPaths() {
    var journal = LibraryChangeJournal()
    journal.recordMoves(["a.mp3": "a.mp3", "b.mp3": "c.mp3"], at: at(1))
    #expect(journal.entries.count == 1)
    #expect(journal.currentPath(for: "b.mp3") == "c.mp3")
}

@Test func fieldEditsAreFoundAcrossAMove() {
    var journal = LibraryChangeJournal()
    journal.record(.trackFieldEdited(path: "old.mp3", field: .album, from: "Unknown Album", to: "Neon Nights"), at: at(2))
    journal.record(.trackMoved(from: "old.mp3", to: "new.mp3"), at: at(3))

    // Asking under either name finds the same edit, because both resolve to
    // the same current path.
    #expect(journal.fieldEdits(for: "old.mp3", field: .album, since: at(1)).count == 1)
    #expect(journal.fieldEdits(for: "new.mp3", field: .album, since: at(1)).count == 1)
}

@Test func fieldEditsIgnoreOtherFieldsAndEarlierEdits() {
    var journal = LibraryChangeJournal()
    journal.record(.trackFieldEdited(path: "a.mp3", field: .album, from: nil, to: "Early"), at: at(1))
    journal.record(.trackFieldEdited(path: "a.mp3", field: .genre, from: nil, to: "House"), at: at(4))
    journal.record(.trackFieldEdited(path: "a.mp3", field: .album, from: "Early", to: "Late"), at: at(5))

    let edits = journal.fieldEdits(for: "a.mp3", field: .album, since: at(3))
    #expect(edits.count == 1)
    #expect(journal.latestRecordedValue(for: "a.mp3", field: .album, since: at(3)) == .some(.some("Late")))
}

@Test func latestRecordedValueIsNilWhenTheJournalHasNoOpinion() {
    let journal = LibraryChangeJournal()
    #expect(journal.latestRecordedValue(for: "a.mp3", field: .album, since: at(0)) == nil)
}

@Test func pruningDropsOnlyOlderEntries() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    journal.record(.trackMoved(from: "c.mp3", to: "d.mp3"), at: at(9))
    let pruned = journal.pruned(before: at(5))
    #expect(pruned.entries.count == 1)
    #expect(pruned.currentPath(for: "a.mp3") == "a.mp3")
}

/// A snapshot older than everything the journal still holds can't be
/// reconciled exactly, and must be refused rather than guessed at.
@Test func snapshotOlderThanTheJournalHorizonIsNotReconcilable() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    let longAgo = at(1).addingTimeInterval(-LibraryChangeJournal.defaultRetention * 2)
    #expect(!journal.canReconcile(snapshotTakenAt: longAgo, now: at(2)))
    #expect(journal.canReconcile(snapshotTakenAt: at(1), now: at(2)))
}

@Test func journalSurvivesASaveAndLoadRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-journal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("change-journal.json")

    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "a.mp3", to: "b.mp3"), at: at(1))
    journal.record(.trackFieldEdited(path: "b.mp3", field: .bpm, from: "128", to: "127.5"), at: at(2))
    try journal.save(to: url)

    let loaded = LibraryChangeJournal.load(from: url)
    #expect(loaded.entries.count == 2)
    #expect(loaded.currentPath(for: "a.mp3") == "b.mp3")
    #expect(loaded.latestRecordedValue(for: "b.mp3", field: .bpm, since: at(0)) == .some(.some("127.5")))
}

@Test func loadingAMissingJournalYieldsAnEmptyOne() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
    #expect(LibraryChangeJournal.load(from: url).entries.isEmpty)
}
