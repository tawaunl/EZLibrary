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

/// What Serato has stored inside one audio file: cue points, saved loops,
/// beatgrid and waveform overview.
///
/// All of it is anchored to absolute positions in the file, so trimming the
/// audio invalidates every one of them. The trim editor reads this first so it
/// can tell the user exactly what they are about to lose.
public struct SeratoAnalysisSummary: Sendable, Equatable {
    /// Number of hot cues Serato has saved on the track.
    public let cuePointCount: Int
    /// Number of saved loops.
    public let loopCount: Int
    public let hasBeatgrid: Bool
    public let hasWaveformOverview: Bool
    /// False when the file's tag format isn't one this reader understands
    /// (anything but MP3 today), meaning the counts are unknown rather than
    /// known-to-be-zero.
    public let isInspectable: Bool

    public init(
        cuePointCount: Int,
        loopCount: Int,
        hasBeatgrid: Bool,
        hasWaveformOverview: Bool,
        isInspectable: Bool
    ) {
        self.cuePointCount = cuePointCount
        self.loopCount = loopCount
        self.hasBeatgrid = hasBeatgrid
        self.hasWaveformOverview = hasWaveformOverview
        self.isInspectable = isInspectable
    }

    /// Nothing found, and we were able to look.
    public static let none = SeratoAnalysisSummary(
        cuePointCount: 0, loopCount: 0, hasBeatgrid: false,
        hasWaveformOverview: false, isInspectable: true)

    /// The file's tags couldn't be inspected, so treat its analysis data as
    /// unknown rather than absent.
    public static let notInspectable = SeratoAnalysisSummary(
        cuePointCount: 0, loopCount: 0, hasBeatgrid: false,
        hasWaveformOverview: false, isInspectable: false)

    public var hasCuesOrLoops: Bool { cuePointCount > 0 || loopCount > 0 }

    public var hasAnyAnalysis: Bool {
        hasCuesOrLoops || hasBeatgrid || hasWaveformOverview
    }

    /// One line describing what a trim will discard, or nil when there is
    /// nothing worth warning about.
    public var trimWarning: String? {
        guard isInspectable else {
            return "This file's Serato data can't be inspected, so any cue points, "
                + "loops or beatgrid it has will be cleared and Serato will re-analyze it."
        }
        guard hasAnyAnalysis else { return nil }

        var lost: [String] = []
        if cuePointCount > 0 {
            lost.append("\(cuePointCount) cue point\(cuePointCount == 1 ? "" : "s")")
        }
        if loopCount > 0 {
            lost.append("\(loopCount) saved loop\(loopCount == 1 ? "" : "s")")
        }
        if hasBeatgrid { lost.append("the beatgrid") }
        if hasWaveformOverview { lost.append("the waveform overview") }

        return "Trimming shifts the whole timeline, so \(joined(lost)) will be cleared. "
            + "Serato will re-analyze the track the next time it loads it."
    }

    private func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }
}

/// Reads the Serato analysis objects out of an audio file's tags.
///
/// Serato writes cue points, loops, the beatgrid and the waveform overview as
/// ID3 `GEOB` frames rather than into `database V2`. Only the leading ID3 tag
/// is read (not the audio), so this is cheap enough to call while the user is
/// dragging trim handles.
public enum SeratoAnalysisTagReader {
    private enum ObjectName {
        static let markersV2 = "Serato Markers2"
        static let markersV1 = "Serato Markers_"
        static let beatgrid = "Serato BeatGrid"
        static let overview = "Serato Overview"
    }

    /// Inspects the file at `url`. Never throws — an unreadable or unsupported
    /// file reports `.notInspectable` so callers can warn conservatively.
    public static func summary(forFileAt url: URL) -> SeratoAnalysisSummary {
        guard url.pathExtension.lowercased() == "mp3" else {
            return .notInspectable
        }
        guard let tag = ID3ArtworkCodec.readID3TagBytes(at: url) else {
            // No ID3 tag at all means Serato has never written analysis here.
            return .none
        }

        let objects = ID3ArtworkCodec.generalObjects(fromID3TagBytes: tag)
        guard !objects.isEmpty else { return .none }

        var cueCount = 0
        var loopCount = 0
        var hasBeatgrid = false
        var hasOverview = false
        var sawMarkersV1 = false

        for object in objects {
            switch object.description {
            case ObjectName.markersV2:
                let entries = decodeMarkers2Entries(object.payload)
                cueCount += entries.filter { $0 == "CUE" }.count
                loopCount += entries.filter { $0 == "LOOP" }.count
            case ObjectName.markersV1:
                sawMarkersV1 = true
            case ObjectName.beatgrid:
                hasBeatgrid = true
            case ObjectName.overview:
                hasOverview = true
            default:
                continue
            }
        }

        // The legacy `Serato Markers_` object carries the same cues in a binary
        // layout. When it's the only marker object present we can't count them,
        // so report one so the user still gets warned.
        if cueCount == 0, loopCount == 0, sawMarkersV1 {
            cueCount = 1
        }

        return SeratoAnalysisSummary(
            cuePointCount: cueCount,
            loopCount: loopCount,
            hasBeatgrid: hasBeatgrid,
            hasWaveformOverview: hasOverview,
            isInspectable: true
        )
    }

    // MARK: - Serato Markers2 decoding

    /// Returns the entry names inside a `Serato Markers2` payload, e.g.
    /// `["COLOR", "CUE", "CUE", "BPMLOCK"]`.
    ///
    /// The payload is two version bytes followed by base64 (which Serato may
    /// pad with NULs or wrap across lines). The decoded blob is another two
    /// version bytes followed by entries of `name\0` + big-endian `UInt32`
    /// length + that many bytes.
    static func decodeMarkers2Entries(_ payload: [UInt8]) -> [String] {
        guard payload.count > 2 else { return [] }
        guard let blob = decodeBase64Body(Array(payload.dropFirst(2))) else { return [] }

        var names: [String] = []
        var index = 2 // skip the decoded blob's own version bytes

        while index < blob.count {
            guard let terminator = blob[index...].firstIndex(of: 0x00) else { break }
            let nameBytes = Array(blob[index..<terminator])
            // A run of trailing NULs marks the end of the entry list.
            guard !nameBytes.isEmpty else { break }
            guard let name = String(bytes: nameBytes, encoding: .isoLatin1) else { break }

            let lengthStart = terminator + 1
            guard lengthStart + 4 <= blob.count else { break }
            let length = (Int(blob[lengthStart]) << 24)
                | (Int(blob[lengthStart + 1]) << 16)
                | (Int(blob[lengthStart + 2]) << 8)
                | Int(blob[lengthStart + 3])
            guard length >= 0, lengthStart + 4 + length <= blob.count else { break }

            names.append(name)
            index = lengthStart + 4 + length
        }

        return names
    }

    /// Decodes Serato's base64 body, which is not reliably padded and can carry
    /// embedded NUL and newline bytes.
    private static func decodeBase64Body(_ bytes: [UInt8]) -> [UInt8]? {
        let cleaned = bytes.filter { $0 != 0x00 && $0 != 0x0A && $0 != 0x0D && $0 != 0x20 }
        guard !cleaned.isEmpty else { return nil }

        // A base64 group of 4 encodes 3 bytes; a remainder of 1 is not decodable.
        var padded = cleaned
        let remainder = padded.count % 4
        if remainder == 1 {
            padded.removeLast()
        } else if remainder > 0 {
            padded.append(contentsOf: [UInt8](repeating: 0x3D, count: 4 - remainder)) // '='
        }

        guard let string = String(bytes: padded, encoding: .ascii),
              let data = Data(base64Encoded: string) else {
            return nil
        }
        return [UInt8](data)
    }
}
