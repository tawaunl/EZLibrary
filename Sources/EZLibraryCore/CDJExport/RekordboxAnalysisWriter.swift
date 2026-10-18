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

/// One beat in a rekordbox beat grid.
public struct CDJBeat: Sendable, Equatable {
    /// Position in the bar, 1...4.
    public var beatNumber: Int
    /// Tempo in hundredths of a BPM.
    public var tempo: Int
    public var timeMs: Int
}

/// What goes into a track's ANLZ analysis files.
public struct CDJAnalysisInput: Sendable {
    public var stickPath: String
    public var durationMs: Int
    public var beats: [CDJBeat]
    public var analysis: SeratoTrackAnalysis
    /// Normalised 0...1 peaks, any length; resampled per waveform kind.
    public var peaks: [Float]

    public init(
        stickPath: String, durationMs: Int, beats: [CDJBeat] = [],
        analysis: SeratoTrackAnalysis = SeratoTrackAnalysis(), peaks: [Float] = []
    ) {
        self.stickPath = stickPath
        self.durationMs = durationMs
        self.beats = beats
        self.analysis = analysis
        self.peaks = peaks
    }
}

/// Writes the `ANLZ0000.DAT` and `ANLZ0000.EXT` analysis files that sit under
/// `PIONEER/USBANLZ/` and give CDJs a track's beat grid, cues and waveforms.
///
/// Both files are big-endian tagged sections inside a `PMAI` container, as
/// described by Deep Symmetry's reverse-engineering notes. Written without
/// access to a deck, so unverified on hardware.
public enum RekordboxAnalysisWriter {
    public static let previewColumns = 400
    public static let tinyPreviewColumns = 100
    public static let scrollColumnsPerSecond = 150

    /// Hot cue slots on a CDJ (A–H).
    static let hotCueSlots = 8

    public static func datFile(_ input: CDJAnalysisInput) -> Data {
        container([
            pathSection(input.stickPath),
            beatGridSection(input.beats),
            previewSection(input.peaks, columns: previewColumns, fourCC: "PWAV"),
            previewSection(input.peaks, columns: tinyPreviewColumns, fourCC: "PWV2"),
            // The legacy lists in the .DAT hold hot cues A-C and the memory cues.
            legacyCueSection(input.analysis, hot: true, slots: [1, 2, 3]),
            legacyCueSection(input.analysis, hot: false, slots: [0])
        ])
    }

    public static func extFile(_ input: CDJAnalysisInput) -> Data {
        container([
            pathSection(input.stickPath),
            scrollWaveformSection(input.peaks, durationMs: input.durationMs),
            // The legacy lists in the .EXT hold hot cues D-P and an empty memory list;
            // the extended lists below carry every cue with colour and comment.
            legacyCueSection(input.analysis, hot: true, slots: Set(4...16)),
            legacyCueSection(input.analysis, hot: false, slots: []),
            extendedCueSection(input.analysis, hot: true),
            extendedCueSection(input.analysis, hot: false)
        ])
    }

    // MARK: - Beat grid

    /// Expands Serato's anchor markers into one entry per beat.
    public static func beats(from markers: [SeratoTrackAnalysis.BeatMarker], durationMs: Int) -> [CDJBeat] {
        guard !markers.isEmpty else { return [] }
        var beats: [CDJBeat] = []
        var beatIndex = 0
        let limit = 200_000

        func add(time: Double, bpm: Double) {
            defer { beatIndex += 1 }
            let ms = Int((time * 1000).rounded(.toNearestOrEven))
            guard ms >= 0, beats.count < limit else { return }
            // Tempo is stored in hundredths of a BPM, clamped to what a deck accepts.
            let tempo = Int((min(max(bpm, 40), 499) * 100).rounded(.toNearestOrEven))
            beats.append(CDJBeat(beatNumber: beatIndex % 4 + 1, tempo: tempo, timeMs: ms))
        }

        for (position, marker) in markers.enumerated() {
            if let count = marker.beatsToNextMarker, position + 1 < markers.count, count > 0 {
                let span = markers[position + 1].positionSeconds - marker.positionSeconds
                guard span > 0 else { continue }
                let bpm = 60 * Double(count) / span
                for beat in 0..<count {
                    add(time: marker.positionSeconds + span * Double(beat) / Double(count), bpm: bpm)
                }
            } else if let bpm = marker.bpm, bpm > 0 {
                let interval = 60 / bpm
                var time = marker.positionSeconds
                let end = Double(durationMs) / 1000
                while time <= end, beats.count < limit {
                    add(time: time, bpm: bpm)
                    time += interval
                }
            }
        }
        return beats
    }

    private static func beatGridSection(_ beats: [CDJBeat]) -> Data {
        var extra = Data()
        extra.appendBE(UInt32(0))
        // Low 16 bits are a signed millisecond grid shift; we apply none.
        extra.appendBE(UInt32(0x0008_0000))
        extra.appendBE(UInt32(beats.count))
        var body = Data()
        for beat in beats {
            body.appendBE(UInt16(beat.beatNumber))
            body.appendBE(UInt16(clamping: beat.tempo))
            body.appendBE(UInt32(beat.timeMs))
        }
        return section("PQTZ", headerExtra: extra, body: body)
    }

    // MARK: - Cues

    private struct CueRecord {
        /// 0 for a memory cue, 1-16 for hot cues A-P.
        var slot: Int
        var isLoop: Bool
        var startMs: Int
        var endMs: Int?
        var color: SeratoTrackAnalysis.RGB
        var name: String
    }

    private static func cueRecords(_ analysis: SeratoTrackAnalysis, hot: Bool) -> [CueRecord] {
        if hot {
            return analysis.cues.filter { $0.index < hotCueSlots }.map {
                CueRecord(slot: $0.index + 1, isLoop: false, startMs: $0.positionMs, endMs: nil,
                          color: $0.color, name: $0.name)
            }
        }
        // Serato's saved loops have no direct equivalent on a CDJ, so they
        // become memory loops, which the deck lists in its memory-cue menu.
        return analysis.loops.map {
            CueRecord(slot: 0, isLoop: true, startMs: $0.startMs, endMs: $0.endMs,
                      color: $0.color, name: $0.name)
        }
    }

    /// A `PCOB` list of 56-byte `PCPT` entries. `slots` limits which hot cues it holds.
    private static func legacyCueSection(_ analysis: SeratoTrackAnalysis, hot: Bool, slots: Set<Int>) -> Data {
        let records = cueRecords(analysis, hot: hot).filter { slots.contains($0.slot) }
        var extra = Data()
        extra.appendBE(UInt32(hot ? 1 : 0))
        extra.appendBE(UInt16(0))
        extra.appendBE(UInt16(records.count))
        // 0xffffffff for hot and empty lists; otherwise the count less one.
        extra.appendBE(hot || records.isEmpty ? UInt32.max : UInt32(records.count - 1))
        var body = Data()
        for (index, record) in records.enumerated() {
            body.append(Data("PCPT".utf8))
            body.appendBE(UInt32(0x1c))
            body.appendBE(UInt32(0x38))
            body.appendBE(UInt32(record.slot))
            body.appendBE(UInt32(0))  // 4 would mark an active loop
            body.appendBE(UInt32(0x10000))
            // Memory entries link to their neighbours; hot cues don't.
            let previous: UInt16 = !hot && index > 0 ? UInt16(index - 1) : 0xffff
            let next: UInt16 = !hot && index + 1 < records.count ? UInt16(index + 1) : 0xffff
            body.appendBE(previous)
            body.appendBE(next)
            body.append(record.isLoop ? 2 : 1)
            body.append(contentsOf: [0x00, 0x03, 0xE8])
            body.appendBE(UInt32(record.startMs))
            body.appendBE(UInt32(record.endMs ?? 0xffff_ffff))
            body.append(Data(count: 16))
        }
        return section("PCOB", headerExtra: extra, body: body)
    }

    /// A `PCO2` list of `PCP2` entries: 88 bytes plus the UTF-16 comment.
    private static func extendedCueSection(_ analysis: SeratoTrackAnalysis, hot: Bool) -> Data {
        let records = cueRecords(analysis, hot: hot)
        var extra = Data()
        extra.appendBE(UInt32(hot ? 1 : 0))
        extra.appendBE(UInt16(records.count))
        extra.appendBE(UInt16(0))
        var body = Data()
        for record in records {
            // A non-empty comment is stored with its terminating NUL.
            var comment = record.name.isEmpty ? Data() : utf16BE(record.name)
            if !comment.isEmpty { comment.append(contentsOf: [0, 0]) }
            let colour = RekordboxCuePalette.nearest(to: record.color)

            var entry = Data()
            entry.append(Data("PCP2".utf8))
            entry.appendBE(UInt32(0x10))
            entry.appendBE(UInt32(88 + comment.count))
            entry.appendBE(UInt32(record.slot))
            entry.append(record.isLoop ? 2 : 1)
            entry.append(contentsOf: [0x00, 0x03, 0xE8])
            entry.appendBE(UInt32(record.startMs))
            entry.appendBE(UInt32(record.endMs ?? 0xffff_ffff))
            entry.append(0x00)  // memory colour id; hot cues use 0
            entry.append(0x01)
            entry.append(Data(count: 0x28 - entry.count))  // loop fraction fields stay zero
            entry.appendBE(UInt32(comment.count))
            entry.append(comment)
            entry.append(contentsOf: [colour.code, colour.red, colour.green, colour.blue])
            entry.append(Data(count: 88 + comment.count - entry.count))
            body.append(entry)
        }
        return section("PCO2", headerExtra: extra, body: body)
    }

    // MARK: - Waveforms

    /// `PWAV` (400 columns) and `PWV2` (100). Neither may contain a zero column,
    /// or a Nexus-era deck discards the whole preview. `PWAV` stops at 25 and
    /// `PWV2` at 15, and `PWV2` has no whiteness bits.
    private static func previewSection(_ peaks: [Float], columns: Int, fourCC: String) -> Data {
        let isMain = fourCC == "PWAV"
        let low = isMain ? 2 : 1
        let high = isMain ? 25 : 15
        let values = AudioWaveformSampler.resample(peaks, to: columns)
        var body = Data()
        for index in 0..<columns {
            let peak = index < values.count ? max(0, min(1, values[index])) : 0
            let height = UInt8(low + Int((peak * Float(high - low)).rounded()))
            body.append(isMain ? (5 << 5) | height : height)
        }
        var extra = Data()
        extra.appendBE(UInt32(columns))
        extra.appendBE(UInt32(0x10000))
        return section(fourCC, headerExtra: extra, body: body)
    }

    private static func scrollWaveformSection(_ peaks: [Float], durationMs: Int) -> Data {
        let columns = max(1, durationMs * scrollColumnsPerSecond / 1000)
        let values = AudioWaveformSampler.resample(peaks, to: columns)
        var body = Data()
        for index in 0..<columns {
            let peak = index < values.count ? max(0, min(1, values[index])) : 0
            body.append((5 << 5) | UInt8((peak * 31).rounded()))
        }
        var extra = Data()
        extra.appendBE(UInt32(1))
        extra.appendBE(UInt32(columns))
        extra.appendBE(UInt32(0x96_0000))
        return section("PWV3", headerExtra: extra, body: body)
    }

    // MARK: - Containers

    private static func pathSection(_ path: String) -> Data {
        var body = utf16BE(path)
        body.append(contentsOf: [0, 0])
        var extra = Data()
        extra.appendBE(UInt32(body.count))
        return section("PPTH", headerExtra: extra, body: body)
    }

    private static func section(_ fourCC: String, headerExtra: Data, body: Data) -> Data {
        var data = Data(fourCC.utf8)
        let headerLength = 12 + headerExtra.count
        data.appendBE(UInt32(headerLength))
        data.appendBE(UInt32(headerLength + body.count))
        data.append(headerExtra)
        data.append(body)
        return data
    }

    private static func container(_ sections: [Data]) -> Data {
        let body = sections.reduce(into: Data()) { $0.append($1) }
        var data = Data("PMAI".utf8)
        data.appendBE(UInt32(0x1c))
        data.appendBE(UInt32(0x1c + body.count))
        // rekordbox's constant header extra, reproduced rather than derived.
        data.appendBE(UInt32(1))
        data.appendBE(UInt32(0x10000))
        data.appendBE(UInt32(0x10000))
        data.appendBE(UInt32(0))
        data.append(body)
        return data
    }

    private static func utf16BE(_ string: String) -> Data {
        string.data(using: .utf16BigEndian) ?? Data()
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
