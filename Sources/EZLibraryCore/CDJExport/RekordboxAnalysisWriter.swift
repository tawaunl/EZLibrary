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
    /// 150 columns per second of three-band peaks; empty when the audio couldn't be decoded.
    public var columns: [CDJBandColumn]

    public init(
        stickPath: String, durationMs: Int, beats: [CDJBeat] = [],
        analysis: SeratoTrackAnalysis = SeratoTrackAnalysis(), columns: [CDJBandColumn] = []
    ) {
        self.stickPath = stickPath
        self.durationMs = durationMs
        self.beats = beats
        self.analysis = analysis
        self.columns = columns
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

    /// `.DAT`: path, VBR table, beat grid, the two previews and the legacy cue lists
    /// (hot cues A-C, then memory cues).
    public static func datFile(_ input: CDJAnalysisInput) -> Data {
        container([
            pathSection(input.stickPath),
            vbrSection(),
            beatGridSection(input.beats),
            previewSection(columns(of: input), count: previewColumns, fourCC: "PWAV"),
            previewSection(columns(of: input), count: tinyPreviewColumns, fourCC: "PWV2"),
            legacyCueSection(input.analysis, hot: true, slots: [1, 2, 3]),
            legacyCueSection(input.analysis, hot: false, slots: [0])
        ])
    }

    /// `.EXT`: the scrolling waveforms, the legacy cue lists for hot cues D-P
    /// and an empty memory list, then the extended cue lists with colour and
    /// comment, and the colour waveforms.
    public static func extFile(_ input: CDJAnalysisInput) -> Data {
        let bands = columns(of: input)
        return container([
            pathSection(input.stickPath),
            scrollSection("PWV3", stride: 1, trailer: 0x0096_0000, data: detailBytes(bands)),
            legacyCueSection(input.analysis, hot: true, slots: Set(4...16)),
            legacyCueSection(input.analysis, hot: false, slots: []),
            extendedCueSection(input.analysis, hot: true),
            extendedCueSection(input.analysis, hot: false),
            scrollSection("PWV5", stride: 2, trailer: 0x0096_0305, data: colourDetailBytes(bands)),
            scrollSection("PWV4", stride: 6, trailer: 0, data: colourPreviewBytes(bands))
        ])
    }

    /// `.2EX`: the CDJ-3000's three-band waveforms.
    public static func twoExFile(_ input: CDJAnalysisInput) -> Data {
        let bands = columns(of: input)
        return container([
            pathSection(input.stickPath),
            scrollSection("PWV7", stride: 3, trailer: 0x0096_0000, data: bandDetailBytes(bands)),
            scrollSection("PWV6", stride: 3, trailer: nil, data: bandOverviewBytes(bands))
        ])
    }

    /// The input's columns, or silence of the right length when the audio couldn't be decoded,
    /// so every file still has the sections a player expects.
    private static func columns(of input: CDJAnalysisInput) -> [CDJBandColumn] {
        if !input.columns.isEmpty { return input.columns }
        let count = max(1, input.durationMs * scrollColumnsPerSecond / 1000)
        return [CDJBandColumn](repeating: CDJBandColumn(), count: count)
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
    //
    // The encodings follow rekordbox's own files. The five-bit heights don't share a
    // ceiling (`PWAV` 25, `PWV2` 15, the scrolling tags 31), and neither preview may
    // contain a zero column or a Nexus-era deck discards the whole preview.

    /// The loudest of each field over the columns that fall in each of `count` buckets.
    private static func resample(_ columns: [CDJBandColumn], to count: Int) -> [CDJBandColumn] {
        guard !columns.isEmpty else { return [CDJBandColumn](repeating: CDJBandColumn(), count: count) }
        return (0..<count).map { bucket in
            let start = bucket * columns.count / count
            let end = min(columns.count, max(start + 1, (bucket + 1) * columns.count / count))
            return columns[start..<end].reduce(CDJBandColumn()) {
                CDJBandColumn(
                    low: max($0.low, $1.low), mid: max($0.mid, $1.mid),
                    high: max($0.high, $1.high), peak: max($0.peak, $1.peak))
            }
        }
    }

    /// A band scaled to the 44-step range the previews and `PWV6` use.
    private static func band(_ value: UInt8) -> UInt32 { UInt32(value) * 44 / 255 }

    /// A preview column's height: its loudest band, up to `ceiling`.
    private static func previewHeight(_ column: CDJBandColumn, ceiling: UInt32) -> UInt32 {
        let loudest = max(band(column.low), band(column.mid), band(column.high))
        return min(ceiling, loudest * ceiling / 44)
    }

    /// A scrolling column's height: its sample peak squared, rounded into five bits.
    private static func detailHeight(_ column: CDJBandColumn) -> UInt32 {
        let full: UInt32 = 255 * 255
        let peak = UInt32(column.peak)
        return min(31, (31 * peak * peak + full / 2) / full)
    }

    /// Height in the low five bits, and above it how much of the column is treble.
    private static func monoByte(_ column: CDJBandColumn, height: UInt32) -> UInt8 {
        let total = UInt32(column.low) + UInt32(column.mid) + UInt32(column.high)
        let whiteness = total == 0 ? 0 : (UInt32(column.high) * 7 + total / 2) / total
        return UInt8((min(whiteness, 7) << 5) | min(height, 31))
    }

    /// `PWAV` (400 columns, height 2...25 plus whiteness) or `PWV2` (100 columns, height 1...15 alone).
    private static func previewSection(_ bands: [CDJBandColumn], count: Int, fourCC: String) -> Data {
        let isMain = fourCC == "PWAV"
        var body = Data()
        for column in resample(bands, to: count) {
            if isMain {
                let byte = monoByte(column, height: previewHeight(column, ceiling: 25))
                body.append((byte & 0xe0) | max(byte & 0x1f, 2))
            } else {
                body.append(UInt8(min(max(previewHeight(column, ceiling: 15), 1), 15)))
            }
        }
        var extra = Data()
        extra.appendBE(UInt32(body.count))
        extra.appendBE(UInt32(0x10000))
        return section(fourCC, headerExtra: extra, body: body)
    }

    private static func detailBytes(_ bands: [CDJBandColumn]) -> Data {
        Data(bands.map { monoByte($0, height: detailHeight($0)) })
    }

    /// `PWV4`: 1,200 columns of six bytes: peak, two unknown zeros, then low, mid and high.
    /// Mid and high are weighted down, which is what the decks' own colour matching expects.
    private static func colourPreviewBytes(_ bands: [CDJBandColumn]) -> Data {
        func weigh(_ value: UInt8, _ numerator: UInt32, _ denominator: UInt32) -> UInt8 {
            UInt8(min(127, UInt32(value >> 1) * numerator / denominator))
        }
        var body = Data()
        for column in resample(bands, to: 1200) {
            body.append(contentsOf: [
                column.peak >> 1, 0, 0, column.low >> 1, weigh(column.mid, 4, 5), weigh(column.high, 13, 20)
            ])
        }
        return body
    }

    /// `PWV5`: a big-endian word per column, `rrrgggbbbhhhhh00`. Red, green and blue are
    /// the low, mid and high bands as shares of the strongest (green at most 5), so the
    /// colour says what the column holds and the height alone how loud it is.
    private static func colourDetailBytes(_ bands: [CDJBandColumn]) -> Data {
        var body = Data()
        for column in bands {
            let low = 2 * UInt32(column.low)
            let mid = 2 * UInt32(column.mid)
            let high = 3 * UInt32(column.high)
            let strongest = max(low, mid, high)
            var red: UInt32 = 0
            var green: UInt32 = 0
            var blue: UInt32 = 0
            if strongest > 0 {
                func share(_ value: UInt32, _ full: UInt32) -> UInt32 { (2 * full * value + strongest) / (2 * strongest) }
                red = share(low, 7)
                green = share(mid, 5)
                blue = share(high, 7)
            }
            body.appendBE(UInt16(red << 13 | green << 10 | blue << 7 | detailHeight(column) << 2))
        }
        return body
    }

    /// `PWV7`: three bytes per column (low, mid, high), seven-bit.
    private static func bandDetailBytes(_ bands: [CDJBandColumn]) -> Data {
        var body = Data()
        for column in bands { body.append(contentsOf: [column.low >> 1, column.mid >> 1, column.high >> 1]) }
        return body
    }

    /// `PWV6`: 1,200 columns of three bytes (low, mid, high).
    private static func bandOverviewBytes(_ bands: [CDJBandColumn]) -> Data {
        var body = Data()
        for column in resample(bands, to: 1200) {
            body.append(contentsOf: [UInt8(band(column.low)), UInt8(band(column.mid)), UInt8(band(column.high))])
        }
        return body
    }

    /// A scrolling waveform: the stride, the number of entries, and a tag-specific
    /// constant. `PWV6` has no such constant, so its header is 20 bytes, not 24.
    private static func scrollSection(_ fourCC: String, stride: Int, trailer: UInt32?, data: Data) -> Data {
        var extra = Data()
        extra.appendBE(UInt32(stride))
        extra.appendBE(UInt32(data.count / stride))
        if let trailer { extra.appendBE(trailer) }
        return section(fourCC, headerExtra: extra, body: data)
    }

    /// The seek table of a VBR file. rekordbox 6 and 7 reject a `.DAT` without one;
    /// all zeros is what it writes for a track with no VBR frames to index.
    private static func vbrSection() -> Data {
        var extra = Data()
        extra.appendBE(UInt32(0))
        return section("PVBR", headerExtra: extra, body: Data(count: 401 * 4))
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
