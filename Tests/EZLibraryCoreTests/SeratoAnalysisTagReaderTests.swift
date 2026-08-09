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

struct SeratoAnalysisTagReaderTests {

    // MARK: - Fixtures

    /// Builds a `Serato Markers2` payload the way Serato does: two version
    /// bytes, then base64 of (two more version bytes + `name\0` + big-endian
    /// length + data entries).
    private func markers2Payload(entries: [(name: String, data: [UInt8])]) -> [UInt8] {
        var blob: [UInt8] = [0x01, 0x01]
        for entry in entries {
            blob.append(contentsOf: Array(entry.name.utf8))
            blob.append(0x00)
            let length = UInt32(entry.data.count)
            blob.append(contentsOf: [
                UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)
            ])
            blob.append(contentsOf: entry.data)
        }
        let base64 = Data(blob).base64EncodedString()
        return [0x01, 0x01] + Array(base64.utf8)
    }

    private func geobFrame(description: String, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [0x00] // ISO-8859-1
        body.append(contentsOf: Array("application/octet-stream".utf8))
        body.append(0x00) // MIME terminator
        body.append(0x00) // empty filename
        body.append(contentsOf: Array(description.utf8))
        body.append(0x00) // description terminator
        body.append(contentsOf: payload)

        var frame: [UInt8] = Array("GEOB".utf8)
        let size = UInt32(body.count)
        frame.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)
        ])
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(contentsOf: body)
        return frame
    }

    /// An MP3 whose only real content is the ID3v2.3 tag — enough for a reader
    /// that never touches the audio.
    private func writeMP3(withFrames frames: [UInt8]) throws -> URL {
        var tag: [UInt8] = Array("ID3".utf8) + [0x03, 0x00, 0x00]
        let size = frames.count
        tag.append(contentsOf: [
            UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
            UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)
        ])
        tag.append(contentsOf: frames)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString).mp3")
        try Data(tag).write(to: url)
        return url
    }

    // MARK: - Tests

    @Test func countsCuePointsAndLoopsFromMarkers2() throws {
        let payload = markers2Payload(entries: [
            ("COLOR", [0x00, 0xFF, 0xFF, 0xFF]),
            ("CUE", [0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0xCC, 0x00, 0x00, 0x00]),
            ("CUE", [0x01, 0x00, 0x00, 0x1F, 0x40, 0x00, 0x00, 0xCC, 0x00, 0x00]),
            ("LOOP", [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x20, 0x00, 0x00]),
            ("BPMLOCK", [0x01])
        ])
        let url = try writeMP3(withFrames:
            geobFrame(description: "Serato Markers2", payload: payload)
            + geobFrame(description: "Serato BeatGrid", payload: [0x01, 0x00, 0x00])
            + geobFrame(description: "Serato Overview", payload: [0x01, 0x05, 0x10]))
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SeratoAnalysisTagReader.summary(forFileAt: url)

        #expect(summary.isInspectable)
        #expect(summary.cuePointCount == 2)
        #expect(summary.loopCount == 1)
        #expect(summary.hasBeatgrid)
        #expect(summary.hasWaveformOverview)
        #expect(summary.hasCuesOrLoops)
    }

    @Test func reportsNoAnalysisForATagWithoutSeratoObjects() throws {
        // A TIT2 title frame and nothing else.
        var titleFrame: [UInt8] = Array("TIT2".utf8) + [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00]
        titleFrame.append(contentsOf: Array("Hello".utf8))

        let url = try writeMP3(withFrames: titleFrame)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SeratoAnalysisTagReader.summary(forFileAt: url)

        #expect(summary.isInspectable)
        #expect(!summary.hasAnyAnalysis)
        #expect(summary.trimWarning == nil)
    }

    /// The legacy binary marker object can't be counted, but its presence must
    /// still produce a warning rather than a silent "nothing to lose".
    @Test func legacyMarkersObjectStillWarns() throws {
        let url = try writeMP3(withFrames:
            geobFrame(description: "Serato Markers_", payload: [0x02, 0x05, 0x00, 0x00]))
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SeratoAnalysisTagReader.summary(forFileAt: url)

        #expect(summary.hasCuesOrLoops)
        #expect(summary.trimWarning != nil)
    }

    @Test func nonMP3FilesReportAsNotInspectable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString).m4a")
        try Data("not really audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SeratoAnalysisTagReader.summary(forFileAt: url)

        #expect(!summary.isInspectable)
        // Unknown analysis still warns, since we can't prove there's none.
        #expect(summary.trimWarning != nil)
    }

    @Test func malformedBase64DoesNotCrashOrOverCount() {
        let entries = SeratoAnalysisTagReader.decodeMarkers2Entries([0x01, 0x01, 0xFF, 0xFE])
        #expect(entries.isEmpty)
    }

    @Test func truncatedEntryLengthStopsDecoding() {
        // "CUE" declares 200 bytes of data but only 2 follow.
        var blob: [UInt8] = [0x01, 0x01]
        blob.append(contentsOf: Array("CUE".utf8))
        blob.append(0x00)
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0xC8])
        blob.append(contentsOf: [0x01, 0x02])

        let payload: [UInt8] = [0x01, 0x01] + Array(Data(blob).base64EncodedString().utf8)
        #expect(SeratoAnalysisTagReader.decodeMarkers2Entries(payload).isEmpty)
    }

    @Test func warningNamesEverythingThatWillBeLost() throws {
        let summary = SeratoAnalysisSummary(
            cuePointCount: 3, loopCount: 1, hasBeatgrid: true,
            hasWaveformOverview: true, isInspectable: true)

        let warning = try #require(summary.trimWarning)
        #expect(warning.contains("3 cue points"))
        #expect(warning.contains("1 saved loop"))
        #expect(warning.contains("the beatgrid"))
    }
}
