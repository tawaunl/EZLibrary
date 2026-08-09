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
import AVFoundation
@testable import EZLibraryCore

struct SeratoTrackMetadataUpdateTests {

    private func padded() -> SeratoTrackMetadataUpdate {
        SeratoTrackMetadataUpdate(
            title: "  Dump Truck  ",
            artist: " E-40 & Too $hort ",
            album: "\tSingle\t",
            genre: " Hip-Hop\n",
            comment: "  from youtube  ",
            key: " 8A ",
            bpm: 128,
            year: 2012
        )
    }

    @Test func initTrimsEveryTextField() {
        let metadata = padded()

        #expect(metadata.title == "Dump Truck")
        #expect(metadata.artist == "E-40 & Too $hort")
        #expect(metadata.album == "Single")
        #expect(metadata.genre == "Hip-Hop")
        #expect(metadata.comment == "from youtube")
        #expect(metadata.key == "8A")
    }

    /// Several callers build a value and then assign fields onto it (the
    /// YouTube importer's `enrichMetadata` does exactly this), so trimming in
    /// the initialiser alone would leave a hole.
    @Test func laterAssignmentIsTrimmedToo() {
        var metadata = padded()

        metadata.artist = "  Drake  "
        metadata.title = "\nFamily Matters\n"
        metadata.album = " Album "
        metadata.genre = "  Rap "
        metadata.comment = " note "
        metadata.key = "  1A  "

        #expect(metadata.artist == "Drake")
        #expect(metadata.title == "Family Matters")
        #expect(metadata.album == "Album")
        #expect(metadata.genre == "Rap")
        #expect(metadata.comment == "note")
        #expect(metadata.key == "1A")
    }

    @Test func interiorSpacingIsLeftAlone() {
        let metadata = SeratoTrackMetadataUpdate(
            title: "  Dump  Truck  ", artist: "A  B", album: "", genre: "",
            comment: "", key: "", bpm: nil, year: nil)

        // Only the ends are touched — collapsing interior runs would rewrite
        // titles that legitimately contain them.
        #expect(metadata.title == "Dump  Truck")
        #expect(metadata.artist == "A  B")
    }

    @Test func aWhitespaceOnlyFieldBecomesEmpty() {
        let metadata = SeratoTrackMetadataUpdate(
            title: "   ", artist: "\t\n", album: "", genre: "",
            comment: "", key: "", bpm: nil, year: nil)

        #expect(metadata.title.isEmpty)
        #expect(metadata.artist.isEmpty)
    }

    /// Non-breaking spaces are what actually arrive from pasted web pages, and
    /// they're invisible in the field, so they have to go too.
    @Test func trimsNonBreakingSpaces() {
        let metadata = SeratoTrackMetadataUpdate(
            title: "\u{00A0}Title\u{00A0}", artist: "", album: "", genre: "",
            comment: "", key: "", bpm: nil, year: nil)

        #expect(metadata.title == "Title")
    }

    @Test func alreadyCleanValuesAreUnchanged() {
        let metadata = SeratoTrackMetadataUpdate(
            title: "Dump Truck", artist: "E-40", album: "Single", genre: "Rap",
            comment: "c", key: "8A", bpm: 128, year: 2012)

        #expect(metadata.title == "Dump Truck")
        #expect(metadata.artist == "E-40")
        #expect(metadata.bpm == 128)
        #expect(metadata.year == 2012)
    }

    // MARK: - Reaching the writers

    /// The point of normalising on the type: padded input must not reach
    /// `database V2`, whichever writer put it there.
    @Test func paddingNeverReachesTheDatabase() throws {
        let inserted = SeratoDatabaseWriter.ensuringTrackExists(
            forStoredPath: "Music/track.mp3",
            metadata: padded(),
            in: Data()
        )

        let tracks = SeratoDatabaseParser.parseTracks(
            from: inserted.data, rootDirectory: URL(fileURLWithPath: "/"))
        let track = try #require(tracks.first)

        #expect(track.title == "Dump Truck")
        #expect(track.artist == "E-40 & Too $hort")
        #expect(track.album == "Single")
        #expect(track.genre == "Hip-Hop")
    }

    /// Padding used to survive into the rendered file name as a doubled
    /// separator, e.g. `Artist -Title`.
    @Test func paddingNeverReachesTheFilename() {
        let stem = TrackFilenameFormatter.renderStem(
            for: padded(), template: "{artist}-{title}-{album}-{year}")

        #expect(stem == "E-40 & Too $hort-Dump Truck-Single-2012")
    }

    /// The other writer: the file's own ID3 frames, checked by reading them
    /// back off a real MP3 rather than trusting the type in isolation.
    @Test func paddingNeverReachesTheFilesID3Frames() async throws {
        guard let ffmpeg = AudioTrimService.ffmpegExecutablePath() else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("track.mp3")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:a", "libmp3lame", url.path
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        try SeratoTrackMetadataEditor.writeID3Tags(fileURL: url, metadata: padded())

        let common = try await AVURLAsset(url: url).load(.commonMetadata)
        let title = try await common.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
        let artist = try await common.first { $0.commonKey == .commonKeyArtist }?.load(.stringValue)

        #expect(title == "Dump Truck")
        #expect(artist == "E-40 & Too $hort")
    }
}
