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

/// The cue points, loops and beatgrid Serato stored in one audio file's tags.
public struct SeratoTrackAnalysis: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public struct Cue: Sendable, Equatable {
        /// Serato's slot, 0-based (slot 0 is the first hot cue).
        public var index: Int
        public var positionMs: Int
        public var color: RGB
        public var name: String
    }

    public struct Loop: Sendable, Equatable {
        public var index: Int
        public var startMs: Int
        public var endMs: Int
        public var color: RGB
        public var name: String
    }

    /// One beatgrid anchor. Non-terminal markers say how many beats lie
    /// between them and the next marker; the final marker carries a BPM.
    public struct BeatMarker: Sendable, Equatable {
        public var positionSeconds: Double
        public var beatsToNextMarker: Int?
        public var bpm: Double?
    }

    public var cues: [Cue]
    public var loops: [Loop]
    public var beatgrid: [BeatMarker]

    public init(cues: [Cue] = [], loops: [Loop] = [], beatgrid: [BeatMarker] = []) {
        self.cues = cues
        self.loops = loops
        self.beatgrid = beatgrid
    }

    public var isEmpty: Bool { cues.isEmpty && loops.isEmpty && beatgrid.isEmpty }
}

extension SeratoAnalysisTagReader {
    /// Reads cues, loops and the beatgrid from a file's Serato tags (MP3, AIFF,
    /// WAV, FLAC and M4A). Returns nil for file types this reader doesn't
    /// understand, and an empty analysis for files Serato never analysed.
    public static func analysis(forFileAt url: URL) -> SeratoTrackAnalysis? {
        guard let objects = SeratoTagContainers.objects(forFileAt: url) else { return nil }

        var result = SeratoTrackAnalysis()
        if let payload = objects[SeratoTagContainers.markers2] {
            let normalized = SeratoTagContainers.normalized(payload, expectingPrefix: [0x01, 0x01])
            for record in decodeMarkers2Records(normalized) {
                switch record.name {
                case "CUE": if let cue = parseCue(record.data) { result.cues.append(cue) }
                case "LOOP": if let loop = parseLoop(record.data) { result.loops.append(loop) }
                default: continue
                }
            }
        }
        if let payload = objects[SeratoTagContainers.beatgrid] {
            result.beatgrid = parseBeatgrid(SeratoTagContainers.normalized(payload, expectingPrefix: [0x01, 0x00]))
        }
        result.cues.sort { $0.index < $1.index }
        result.loops.sort { $0.index < $1.index }
        return result
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func nullTerminatedString(_ bytes: [UInt8], from offset: Int) -> String {
        guard offset < bytes.count else { return "" }
        let slice = bytes[offset...].prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }

    /// `CUE`: 0x00, index, position ms (u32), 0x00, R, G, B, 2 reserved, name\0.
    static func parseCue(_ data: [UInt8]) -> SeratoTrackAnalysis.Cue? {
        guard data.count >= 10, let position = bigEndianUInt32(data, at: 2) else { return nil }
        return SeratoTrackAnalysis.Cue(
            index: Int(data[1]), positionMs: Int(position),
            color: .init(red: data[7], green: data[8], blue: data[9]),
            name: nullTerminatedString(data, from: 12))
    }

    /// `LOOP`: 0x00, index, start ms, end ms, 4 x 0xFF, 0x00, 4-byte colour, locked, name\0.
    static func parseLoop(_ data: [UInt8]) -> SeratoTrackAnalysis.Loop? {
        guard data.count >= 19, let start = bigEndianUInt32(data, at: 2),
              let end = bigEndianUInt32(data, at: 6), end > start else { return nil }
        return SeratoTrackAnalysis.Loop(
            index: Int(data[1]), startMs: Int(start), endMs: Int(end),
            color: .init(red: data[16], green: data[17], blue: data[18]),
            name: nullTerminatedString(data, from: 20))
    }

    /// `Serato BeatGrid`: 2 version bytes, marker count (u32), then big-endian
    /// float position + u32 beat count for each non-terminal marker, and a
    /// float position + float BPM for the terminal one.
    static func parseBeatgrid(_ payload: [UInt8]) -> [SeratoTrackAnalysis.BeatMarker] {
        guard let count = bigEndianUInt32(payload, at: 2), count > 0, count < 10_000 else { return [] }
        var markers: [SeratoTrackAnalysis.BeatMarker] = []
        var offset = 6
        for position in 0..<Int(count) {
            guard let rawPosition = bigEndianUInt32(payload, at: offset),
                  let second = bigEndianUInt32(payload, at: offset + 4) else { return markers }
            let seconds = Double(Float(bitPattern: rawPosition))
            guard seconds.isFinite else { return markers }
            if position == Int(count) - 1 {
                let bpm = Double(Float(bitPattern: second))
                guard bpm.isFinite, bpm > 0 else { return markers }
                markers.append(.init(positionSeconds: seconds, beatsToNextMarker: nil, bpm: bpm))
            } else {
                markers.append(.init(positionSeconds: seconds, beatsToNextMarker: Int(second), bpm: nil))
            }
            offset += 8
        }
        return markers
    }
}
