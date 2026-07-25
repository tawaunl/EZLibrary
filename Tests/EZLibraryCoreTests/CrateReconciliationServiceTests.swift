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

private func crate(_ name: String, _ trackPaths: [String]) -> Crate {
    Crate(
        pathComponents: [name],
        trackPaths: trackPaths,
        fileURL: URL(fileURLWithPath: "/tmp/_Serato_/Subcrates/\(name).crate")
    )
}

@Test func deletedTrackIsReplacedByTheKeptCopyInPlace() {
    // The crate references the copy being deleted but not the one being kept.
    // Dropping the path would silently shorten the crate.
    let party = crate("Party", ["Music/a.mp3", "Music/dup.mp3", "Music/b.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [party],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    let change = plan.changes[party.id]
    #expect(change?.trackPaths == ["Music/a.mp3", "Music/keep.mp3", "Music/b.mp3"])
    #expect(change?.repointedCount == 1)
    #expect(change?.removedCount == 0)
    #expect(plan.emptiedCrateNames.isEmpty)
}

@Test func crateKeepsItsLengthAfterReconciliation() {
    let party = crate("Party", ["Music/a.mp3", "Music/dup.mp3", "Music/b.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [party],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    #expect(plan.changes[party.id]?.trackPaths.count == party.trackPaths.count)
}

@Test func duplicateEntryIsRemovedWhenTheKeptCopyIsAlreadyPresent() {
    // Re-pointing here would list the same track twice.
    let party = crate("Party", ["Music/keep.mp3", "Music/dup.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [party],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    let change = plan.changes[party.id]
    #expect(change?.trackPaths == ["Music/keep.mp3"])
    #expect(change?.removedCount == 1)
    #expect(change?.repointedCount == 0)
}

@Test func aCrateBuiltOnlyFromDeletedCopiesIsRepointedNotEmptied() {
    let onlyDupes = crate("Old Rips", ["Music/dup1.mp3", "Music/dup2.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [onlyDupes],
        deletedPaths: ["Music/dup1.mp3", "Music/dup2.mp3"],
        keptPathForDeleted: [
            "Music/dup1.mp3": "Music/keep1.mp3",
            "Music/dup2.mp3": "Music/keep2.mp3"
        ]
    )

    #expect(plan.changes[onlyDupes.id]?.trackPaths == ["Music/keep1.mp3", "Music/keep2.mp3"])
    #expect(plan.emptiedCrateNames.isEmpty)
}

@Test func emptiedCrateIsReportedWhenThereIsNoSurvivingCopy() {
    // No kept copy to substitute, so the crate really does lose everything.
    let doomed = crate("Doomed", ["Music/dup.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [doomed],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: [:]
    )

    #expect(plan.changes[doomed.id]?.trackPaths.isEmpty == true)
    #expect(plan.emptiedCrateNames == ["Doomed"])
}

@Test func cratesWithoutDeletedTracksAreUntouched() {
    let unaffected = crate("Chill", ["Music/x.mp3", "Music/y.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [unaffected],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    #expect(plan.isEmpty)
    #expect(plan.changes[unaffected.id] == nil)
}

@Test func aKeptPathThatIsItselfBeingDeletedIsNotSubstituted() {
    // Guards against re-pointing at a copy that won't survive either.
    let party = crate("Party", ["Music/dup.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [party],
        deletedPaths: ["Music/dup.mp3", "Music/alsoGone.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/alsoGone.mp3"]
    )

    #expect(plan.changes[party.id]?.trackPaths.isEmpty == true)
    #expect(plan.changes[party.id]?.removedCount == 1)
}

@Test func nonCrateFilesAreSkipped() {
    var smart = crate("Smart", ["Music/dup.mp3"])
    smart.fileURL = URL(fileURLWithPath: "/tmp/_Serato_/Smart.smartcrate")

    let plan = CrateReconciliationService.plan(
        crates: [smart],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    #expect(plan.isEmpty)
}

@Test func planSpansMultipleCrates() {
    let a = crate("A", ["Music/dup.mp3", "Music/x.mp3"])
    let b = crate("B", ["Music/y.mp3", "Music/dup.mp3"])

    let plan = CrateReconciliationService.plan(
        crates: [a, b],
        deletedPaths: ["Music/dup.mp3"],
        keptPathForDeleted: ["Music/dup.mp3": "Music/keep.mp3"]
    )

    #expect(plan.affectedCrateCount == 2)
    #expect(plan.totalRepointed == 2)
    #expect(CrateReconciliationService.summary(for: plan)?.contains("2 crates") == true)
}

@Test func emptyDeletionPlansNothing() {
    let plan = CrateReconciliationService.plan(
        crates: [crate("A", ["Music/x.mp3"])],
        deletedPaths: [],
        keptPathForDeleted: [:]
    )
    #expect(plan.isEmpty)
    #expect(CrateReconciliationService.summary(for: plan) == nil)
}
