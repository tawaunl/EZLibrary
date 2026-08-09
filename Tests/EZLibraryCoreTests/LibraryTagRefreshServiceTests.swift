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

private func makeTrack(
    fileURL: URL,
    title: String = "",
    artist: String = "",
    album: String = "",
    genre: String = "",
    year: Int? = nil
) -> Track {
    Track(
        seratoStoredPath: String(fileURL.path.dropFirst()),
        fileURL: fileURL,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        comment: "",
        year: year,
        bpm: nil,
        key: nil
    )
}

/// A track whose file is gone can't be checked, so it is reported rather than
/// silently skipped or blanked out.
@Test func refreshReportsTracksWhoseFileIsMissing() async {
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/Gone.mp3")
    let plan = await LibraryTagRefreshService.plan(for: [makeTrack(fileURL: missing, title: "Whatever")])

    #expect(plan.changes.isEmpty)
    #expect(plan.missingFiles.count == 1)
}

/// A file with no readable tags must never blank out what the library holds.
@Test func refreshLeavesLibraryAloneWhenTheFileHasNoTags() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tag-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Not real audio, so there is nothing to read.
    let file = directory.appendingPathComponent("Untagged.mp3")
    try Data("not audio".utf8).write(to: file)

    let plan = await LibraryTagRefreshService.plan(
        for: [makeTrack(fileURL: file, title: "Keep This", artist: "Keep This Too")]
    )

    #expect(plan.changes.isEmpty)
    #expect(plan.untaggedFiles.count == 1)
}

@Test func fieldChangeCarriesBeforeAndAfter() {
    let change = LibraryTagRefreshService.FieldChange(field: "Title", before: "Song 2", after: "Song")
    #expect(change.field == "Title")
    #expect(change.before == "Song 2")
    #expect(change.after == "Song")
}

/// Applying an empty plan must not rewrite — and must not snapshot — anything.
@Test func applyingAnEmptyPlanIsANoOp() throws {
    let plan = LibraryTagRefreshService.Plan(
        changes: [], missingFiles: [], untaggedFiles: [], unchangedCount: 3
    )
    let written = try LibraryTagRefreshService.apply(
        plan,
        databaseFileURL: URL(fileURLWithPath: "/nonexistent/database V2")
    )
    #expect(written == 0)
}

// MARK: - Filename index prefixes

/// Stripping any leading number as a track index destroyed artists whose names
/// begin with digits — "50 Cent" became "Cent" and "112" was wiped entirely.
@Test func leadingNumberIsKeptWhenItIsPartOfTheArtistName() {
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("50 Cent") == "50 Cent")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("2 Pac") == "2 Pac")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("112") == "112")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("702 ft Pharrell") == "702 ft Pharrell")
    #expect(
        LibraryFolderSyncService.normalizeFilenameComponent("112 - Its Over Now")
            == "112 - Its Over Now"
    )
}

/// Real index prefixes are still removed.
@Test func realTrackIndexPrefixesAreStillStripped() {
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("01 - Song Name") == "Song Name")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("07 Song Name") == "Song Name")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("1. Song Name") == "Song Name")
    #expect(LibraryFolderSyncService.normalizeFilenameComponent("3) Song Name") == "Song Name")
}

/// The artist survives end to end, not just in the normalizer.
@Test func numericArtistSurvivesFilenameParsing() {
    let metadata = LibraryFolderSyncService.filenameMetadata(
        for: URL(fileURLWithPath: "/tmp/112 ft Lil' Zane - Anywhere (Intro Dirty) 2.mp3"),
        template: "{artist} - {title}"
    )

    #expect(metadata.artist == "112 ft Lil' Zane")
}

/// Only the unambiguous `(2)` collision form is stripped from a guessed title.
///
/// A bare trailing number cannot be told apart from a real title — "Strawberry
/// Letter 23", "Horn 1", "I Need a Girl, Part 2" — so it is left alone, and a
/// file that picked one up is corrected by reading its tags instead.
@Test func onlyTheUnambiguousCollisionFormIsStrippedFromAGuessedTitle() {
    func title(_ name: String) -> String {
        LibraryFolderSyncService.filenameMetadata(
            for: URL(fileURLWithPath: "/tmp/\(name).mp3"),
            template: "{artist} - {title}"
        ).title
    }

    #expect(title("Sia - Titanium (2)") == "Titanium")
    #expect(title("Brothers Johnson - Strawberry Letter 23") == "Strawberry Letter 23")
    #expect(title("P. Diddy - I Need a Girl, Part 2") == "I Need a Girl, Part 2")
}
