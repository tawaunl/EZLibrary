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

struct TagWhitespaceCleanupServiceTests {

    private func track(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        genre: String = "Genre",
        comment: String = "",
        key: String? = nil,
        name: String = "track.mp3"
    ) -> Track {
        Track(
            seratoStoredPath: "Music/\(name)",
            fileURL: URL(fileURLWithPath: "/Music/\(name)"),
            title: title, artist: artist, album: album,
            genre: genre, comment: comment, key: key
        )
    }

    // MARK: - Detection

    @Test func findsTrailingAndLeadingPadding() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(artist: "50 Cent "),
            track(title: " Le Freak", album: "C'est Chic "),
            track(title: " BOP ")
        ])

        #expect(findings.count == 3)
        #expect(findings[0].fields == ["Artist"])
        #expect(findings[1].fields == ["Title", "Album"])
        #expect(findings[2].fields == ["Title"])
    }

    @Test func ignoresCleanTracks() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(),
            track(title: "Dump  Truck")   // interior spacing is not padding
        ])

        #expect(findings.isEmpty)
    }

    /// Trimming a whitespace-only field would erase a value rather than tidy
    /// one, so those are left for the user to deal with deliberately.
    @Test func ignoresFieldsThatAreOnlyWhitespace() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(title: "   ", artist: "  ")
        ])

        #expect(findings.isEmpty)
    }

    @Test func detectsPaddingInEveryWritableField() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(title: "T ", artist: "A ", album: "Al ",
                  genre: "G ", comment: "C ", key: "8A ")
        ])

        let fields = try? #require(findings.first?.fields)
        #expect(fields == ["Title", "Artist", "Album", "Genre", "Comment", "Key"])
    }

    @Test func detectsNonBreakingSpacePadding() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(artist: "CHIC\u{00A0}")
        ])

        #expect(findings.first?.fields == ["Artist"])
    }

    // MARK: - Updates

    @Test func updatesCarryTrimmedValues() {
        let padded = track(title: " Le Freak", artist: "CHIC ", album: "C'est Chic ")

        let update = TagWhitespaceCleanupService.cleanedUpdate(for: padded)

        #expect(update.title == "Le Freak")
        #expect(update.artist == "CHIC")
        #expect(update.album == "C'est Chic")
    }

    /// The cleanup must not quietly change anything but the whitespace.
    @Test func updatesPreserveEveryOtherValue() {
        var padded = track(artist: "Drake ")
        padded.bpm = 128
        padded.year = 2024

        let update = TagWhitespaceCleanupService.cleanedUpdate(for: padded)

        #expect(update.bpm == 128)
        #expect(update.year == 2024)
        #expect(update.title == "Title")
        #expect(update.genre == "Genre")
    }

    @Test func updatesPairEachFindingWithItsTrack() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(artist: "A ", name: "one.mp3"),
            track(),
            track(title: "T ", name: "three.mp3")
        ])

        let updates = TagWhitespaceCleanupService.updates(for: findings)

        #expect(updates.count == 2)
        #expect(updates[0].0.fileURL.lastPathComponent == "one.mp3")
        #expect(updates[0].1.artist == "A")
        #expect(updates[1].0.fileURL.lastPathComponent == "three.mp3")
        #expect(updates[1].1.title == "T")
    }

    /// Re-running after a clean pass must find nothing left to do.
    @Test func cleaningIsIdempotent() {
        let padded = track(title: " BOP ", artist: "Da Baby ")
        let update = TagWhitespaceCleanupService.cleanedUpdate(for: padded)

        var cleaned = padded
        cleaned.title = update.title
        cleaned.artist = update.artist

        #expect(TagWhitespaceCleanupService.findings(in: [cleaned]).isEmpty)
    }

    // MARK: - Summary

    @Test func summaryCountsAffectedFields() {
        let findings = TagWhitespaceCleanupService.findings(in: [
            track(artist: "A ", name: "one.mp3"),
            track(artist: "B ", name: "two.mp3"),
            track(title: "T ", name: "three.mp3")
        ])

        let summary = TagWhitespaceCleanupService.summary(for: findings)

        #expect(summary.contains("3 tracks"))
        #expect(summary.contains("Artist (2)"))
        #expect(summary.contains("Title (1)"))
    }

    @Test func summaryAgreesInNumber() {
        let one = TagWhitespaceCleanupService.findings(in: [track(artist: "A ")])
        let many = TagWhitespaceCleanupService.findings(in: [
            track(artist: "A ", name: "one.mp3"),
            track(artist: "B ", name: "two.mp3")
        ])

        #expect(TagWhitespaceCleanupService.summary(for: one).hasPrefix("1 track has"))
        #expect(TagWhitespaceCleanupService.summary(for: many).hasPrefix("2 tracks have"))
    }

    @Test func summaryHandlesNothingToDo() {
        #expect(TagWhitespaceCleanupService.summary(for: []).contains("No tags need cleaning"))
    }
}
