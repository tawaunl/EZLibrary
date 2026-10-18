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

private func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func sections(in data: Data) -> [(tag: String, header: Int, length: Int, offset: Int)] {
    func u32(_ at: Int) -> Int {
        Int(data.subdata(in: at..<(at + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }
    var result: [(String, Int, Int, Int)] = []
    var offset = u32(4)  // PMAI header length
    while offset + 12 <= data.count {
        let tag = String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
        result.append((tag, u32(offset + 4), u32(offset + 8), offset))
        offset += u32(offset + 8)
    }
    return result
}

@Test func parsesSeratoCueAndLoopEntries() {
    var cue: [UInt8] = [0x00, 0x02] + be32(15_250) + [0x00, 0xCC, 0x00, 0x00, 0x00, 0x00]
    cue += Array("Drop".utf8) + [0x00]
    let parsed = SeratoAnalysisTagReader.parseCue(cue)
    #expect(parsed?.index == 2)
    #expect(parsed?.positionMs == 15_250)
    #expect(parsed?.color == .init(red: 0xCC, green: 0, blue: 0))
    #expect(parsed?.name == "Drop")

    var loop: [UInt8] = [0x00, 0x00] + be32(1_000) + be32(5_000) + [0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    loop += [0x00, 0x27, 0xAA, 0xE1, 0x00] + Array("Loop A".utf8) + [0x00]
    let parsedLoop = SeratoAnalysisTagReader.parseLoop(loop)
    #expect(parsedLoop?.startMs == 1_000)
    #expect(parsedLoop?.endMs == 5_000)
    #expect(parsedLoop?.name == "Loop A")
}

@Test func rejectsTruncatedOrBackwardsEntries() {
    #expect(SeratoAnalysisTagReader.parseCue([0x00, 0x01, 0x00]) == nil)
    let backwards: [UInt8] = [0, 0] + be32(5_000) + be32(1_000) + [UInt8](repeating: 0, count: 12)
    #expect(SeratoAnalysisTagReader.parseLoop(backwards) == nil)
}

@Test func parsesBeatgridMarkers() {
    func float(_ value: Float) -> [UInt8] { be32(value.bitPattern) }
    let payload: [UInt8] = [0x01, 0x00] + be32(2)
        + float(0.5) + be32(64)
        + float(30.5) + float(128)
        + [0x00]
    let markers = SeratoAnalysisTagReader.parseBeatgrid(payload)
    #expect(markers.count == 2)
    #expect(markers[0].beatsToNextMarker == 64)
    #expect(markers[1].bpm == 128)
    #expect(SeratoAnalysisTagReader.parseBeatgrid([0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]).isEmpty)
}

@Test func expandsBeatgridIntoBarNumberedBeats() {
    let markers: [SeratoTrackAnalysis.BeatMarker] = [
        .init(positionSeconds: 1.0, beatsToNextMarker: 4, bpm: nil),
        .init(positionSeconds: 3.0, beatsToNextMarker: nil, bpm: 120)
    ]
    let beats = RekordboxAnalysisWriter.beats(from: markers, durationMs: 5_000)
    #expect(beats.prefix(4).map(\.timeMs) == [1_000, 1_500, 2_000, 2_500])
    #expect(beats.prefix(4).map(\.beatNumber) == [1, 2, 3, 4])
    #expect(beats[0].tempo == 12_000)
    #expect(beats[4].timeMs == 3_000)
    #expect(beats[4].beatNumber == 1)
    #expect(beats.last!.timeMs <= 5_000)
}

/// A synthetic track: a loud, bass-heavy first half and a quiet, treble-only second half.
private func sampleColumns(count: Int = 600) -> [CDJBandColumn] {
    (0..<count).map { index in
        index < count / 2
            ? CDJBandColumn(low: 220, mid: 60, high: 20, peak: 230)
            : CDJBandColumn(low: 5, mid: 20, high: 120, peak: 120)
    }
}

private func body(of section: (tag: String, header: Int, length: Int, offset: Int), in data: Data) -> Data {
    data.subdata(in: (section.offset + section.header)..<(section.offset + section.length))
}

@Test func datFileHasConsistentSectionsAndBeatGrid() {
    let analysis = SeratoTrackAnalysis(
        cues: [.init(index: 0, positionMs: 2_000, color: .init(red: 1, green: 2, blue: 3), name: "Intro")],
        loops: [.init(index: 0, startMs: 4_000, endMs: 8_000, color: .init(red: 0, green: 0, blue: 0), name: "")])
    let input = CDJAnalysisInput(
        stickPath: "/Contents/A/B/x.mp3", durationMs: 4_000,
        beats: [CDJBeat(beatNumber: 1, tempo: 12_000, timeMs: 500)],
        analysis: analysis, columns: sampleColumns())
    let dat = RekordboxAnalysisWriter.datFile(input)

    #expect(String(decoding: dat.prefix(4), as: UTF8.self) == "PMAI")
    #expect(Int(dat.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) == dat.count)
    let found = sections(in: dat)
    #expect(found.map(\.tag) == ["PPTH", "PVBR", "PQTZ", "PWAV", "PWV2", "PCOB", "PCOB"])
    #expect(found.last.map { $0.offset + $0.length } == dat.count)
    // The container's header extra and the beat grid's header word are rekordbox's constants.
    #expect(Array(dat[12..<28]) == be32(1) + be32(0x10000) + be32(0x10000) + be32(0))
    #expect(Array(dat[(found[2].offset + 16)..<(found[2].offset + 20)]) == be32(0x0008_0000))
    // rekordbox 6 and 7 reject a .DAT without its VBR seek table.
    #expect(found[1].header == 16)
    #expect(found[1].length - found[1].header == 401 * 4)
    #expect(found[3].length - found[3].header == 400)
    #expect(found[4].length - found[4].header == 100)
    // Hot cues (A-C) first, then the memory list holding the loop.
    #expect(dat[found[5].offset + 12 + 3] == 1)
    #expect(found[5].length - found[5].header == 0x38)
    #expect(dat[found[6].offset + 12 + 3] == 0)
    #expect(found[6].length - found[6].header == 0x38)
}

@Test func extFileCarriesCuesAndColourWaveforms() {
    let input = CDJAnalysisInput(
        stickPath: "/Contents/A/B/x.mp3", durationMs: 4_000,
        analysis: SeratoTrackAnalysis(cues: [
            .init(index: 1, positionMs: 100, color: .init(red: 9, green: 8, blue: 7), name: "")]),
        columns: sampleColumns())
    let ext = RekordboxAnalysisWriter.extFile(input)
    let found = sections(in: ext)
    #expect(found.map(\.tag) == ["PPTH", "PWV3", "PCOB", "PCOB", "PCO2", "PCO2", "PWV5", "PWV4"])
    #expect(found[1].length - found[1].header == 600)  // one byte per 1/150 s
    #expect(found[6].length - found[6].header == 1200)  // two bytes per column
    #expect(found[7].length - found[7].header == 1200 * 6)  // 1,200 columns of six bytes
    // Hot cue B lives in the extended list only: the legacy EXT lists start at D.
    #expect(found[2].length == found[2].header)
    #expect(found[4].length - found[4].header == 88)
    #expect(body(of: found[4], in: ext).range(of: Data([0, 9, 8, 7])) == nil)  // snapped to the palette
    // Scroll headers: stride, entries, and each tag's constant.
    func header(_ section: (tag: String, header: Int, length: Int, offset: Int)) -> [UInt32] {
        stride(from: section.offset + 12, to: section.offset + section.header, by: 4).map { at in
            ext.subdata(in: at..<(at + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }
    #expect(header(found[1]) == [1, 600, 0x0096_0000])
    #expect(header(found[6]) == [2, 600, 0x0096_0305])
    #expect(header(found[7]) == [6, 1200, 0])
}

@Test func twoExFileHoldsTheThreeBandWaveforms() {
    let input = CDJAnalysisInput(stickPath: "/Contents/A/B/x.mp3", durationMs: 4_000, columns: sampleColumns())
    let twoEx = RekordboxAnalysisWriter.twoExFile(input)
    let found = sections(in: twoEx)
    #expect(found.map(\.tag) == ["PPTH", "PWV7", "PWV6"])
    #expect(found[1].header == 24)
    #expect(found[1].length - found[1].header == 600 * 3)
    // PWV6's header is 20 bytes, not the 24 the other scroll tags use.
    #expect(found[2].header == 20)
    #expect(found[2].length - found[2].header == 1200 * 3)
    // PWV7 keeps the detail range: the loud bass half reaches 220 >> 1.
    #expect(body(of: found[1], in: twoEx).prefix(3) == Data([110, 30, 10]))
}

@Test func colourWaveformsEncodeBandsAndHeights() {
    let bass = CDJBandColumn(low: 255, mid: 0, high: 0, peak: 255)
    let treble = CDJBandColumn(low: 0, mid: 0, high: 255, peak: 128)
    let ext = RekordboxAnalysisWriter.extFile(CDJAnalysisInput(
        stickPath: "/x.mp3", durationMs: 20, columns: [bass, treble, CDJBandColumn()]))
    let found = sections(in: ext)
    // PWV3: whiteness (the treble share) in the top three bits, height round(31 * (peak/255)^2) below.
    #expect([UInt8](body(of: found[1], in: ext)) == [0b000_11111, 0b111_01000, 0])
    // PWV5: rrrgggbbbhhhhh00, colour as shares of the strongest band.
    let words = stride(from: 0, to: 6, by: 2).map { offset -> UInt16 in
        let bytes = [UInt8](body(of: found[6], in: ext))
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    #expect(words == [7 << 13 | 31 << 2, 7 << 7 | 8 << 2, 0])
}

@Test func analysisFilesAreStagedForTrackWithoutAudio() async throws {
    let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cdjstage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stage) }
    let audioPath = "/Contents/A/B/one.mp3"
    let export = CDJExportTrack(
        id: 300, title: "x", durationSeconds: 5, stickPath: audioPath,
        analyzePath: RekordboxAnalysisPath.datPath(forAudioPath: audioPath))
    #expect(export.analyzePath == "/PIONEER/USBANLZ/P03B/0002F797/ANLZ0000.DAT")
    let item = CDJExportPlan.Item(
        key: "k", source: URL(fileURLWithPath: "/nonexistent/x.flac"), sourceModified: 0, sourceSize: 0,
        conversion: nil, export: export)

    var placements: [String] = []
    let hadSeratoData = try await CDJSeratoExport.writeAnalysis(for: item, analysis: nil, into: stage, placements: &placements)
    #expect(hadSeratoData == false)
    #expect(placements == [
        "PIONEER/USBANLZ/P03B/0002F797/ANLZ0000.DAT", "PIONEER/USBANLZ/P03B/0002F797/ANLZ0000.EXT",
        "PIONEER/USBANLZ/P03B/0002F797/ANLZ0000.2EX"
    ])
    for relative in placements {
        #expect(FileManager.default.fileExists(atPath: stage.appendingPathComponent(relative).path))
    }
}

@Test func analysisFolderIsHashedFromTheFinalAudioPath() {
    // Vectors from the rbxport reference, reproduced from CDJ-3000 firmware 3.20.
    #expect(RekordboxAnalysisPath.datPath(forAudioPath: "/Contents/A/B/one.mp3")
        == "/PIONEER/USBANLZ/P03B/0002F797/ANLZ0000.DAT")
    #expect(RekordboxAnalysisPath.datPath(
        forAudioPath: "/Contents/Hosanna, Westend/Drum Death - Extended Mix/20130688_drum_death_(extended_mix).mp3")
        == "/PIONEER/USBANLZ/P002/0002583E/ANLZ0000.DAT")
    #expect(RekordboxAnalysisPath.datPath(forAudioPath: "/Contents/a.mp3", root: ".PIONEER").hasPrefix("/.PIONEER/USBANLZ/"))
}

@Test func extendedCueEntryMatchesTheReferenceBytes() throws {
    // Hot cue A at 83,032 ms, no loop or comment, colour code 46 (FF005C).
    let input = CDJAnalysisInput(
        stickPath: "/x.mp3", durationMs: 1_000,
        analysis: SeratoTrackAnalysis(cues: [
            .init(index: 0, positionMs: 83_032, color: .init(red: 0xFF, green: 0x00, blue: 0x5C), name: "")]))
    let ext = RekordboxAnalysisWriter.extFile(input)
    let found = sections(in: ext)
    let hot = try #require(found.first { $0.tag == "PCO2" })
    let entry = Array(ext[(hot.offset + hot.header)..<(hot.offset + hot.length)])
    let expected: [UInt8] = [
        0x50, 0x43, 0x50, 0x32, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x58, 0x00, 0x00, 0x00, 0x01,
        0x01, 0x00, 0x03, 0xE8, 0x00, 0x01, 0x44, 0x58, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2E, 0xFF, 0x00, 0x5C
    ] + [UInt8](repeating: 0, count: 40)
    #expect(entry == expected)
}

@Test func cueColoursSnapToThePalette() {
    #expect(RekordboxCuePalette.nearest(to: .init(red: 0xFF, green: 0x00, blue: 0x00)).code == 42)
    #expect(RekordboxCuePalette.nearest(to: .init(red: 0x00, green: 0xFF, blue: 0x00)).code == 21)
    #expect(RekordboxCuePalette.nearest(to: .init(red: 0xFE, green: 0xFE, blue: 0xFE)).code == 64)
    #expect(RekordboxCuePalette.rgb.count == 65)
}

@Test func previewWaveformsNeverContainAZeroColumnOrExceedTheirCeiling() {
    // Mostly silence with the odd loud column: the quiet ones must still not be zero.
    let input = CDJAnalysisInput(
        stickPath: "/x.mp3", durationMs: 10_000,
        columns: (0..<1500).map { $0 % 7 == 0 ? CDJBandColumn(low: 255, mid: 255, high: 255, peak: 255) : CDJBandColumn() })
    let dat = RekordboxAnalysisWriter.datFile(input)
    let found = sections(in: dat)
    let pwav = body(of: found[3], in: dat)
    let pwv2 = body(of: found[4], in: dat)
    #expect(pwav.map { $0 & 0x1f }.allSatisfy { (2...25).contains($0) })
    #expect(pwv2.allSatisfy { (1...15).contains($0) })  // height only, no whiteness bits
}

@Test func beatTemposAreClampedAndGridTimesRoundTiesToEven() {
    let markers: [SeratoTrackAnalysis.BeatMarker] = [.init(positionSeconds: 0, beatsToNextMarker: nil, bpm: 600)]
    let beats = RekordboxAnalysisWriter.beats(from: markers, durationMs: 1_000)
    #expect(beats.allSatisfy { $0.tempo == 49_900 })
}

@Test func legacyMemoryListCountsAndLinksEntries() {
    let loops = (0..<3).map {
        SeratoTrackAnalysis.Loop(index: $0, startMs: $0 * 1000, endMs: $0 * 1000 + 500,
                                 color: .init(red: 0, green: 0, blue: 0), name: "")
    }
    let dat = RekordboxAnalysisWriter.datFile(CDJAnalysisInput(
        stickPath: "/x.mp3", durationMs: 5_000, analysis: SeratoTrackAnalysis(loops: loops)))
    let memory = sections(in: dat).last!
    func u32(_ at: Int) -> UInt32 { dat.subdata(in: at..<(at + 4)).reduce(0) { ($0 << 8) | UInt32($1) } }
    #expect(u32(memory.offset + 0x14) == 2)  // count less one
    let second = memory.offset + memory.header + 0x38
    #expect(dat.subdata(in: (second + 0x18)..<(second + 0x1c)) == Data([0, 0, 0, 2]))  // previous 0, next 2
}

@Test func pdbTrackRowPointsAtAnalysisFiles() {
    let track = CDJExportTrack(
        id: 1, title: "t", stickPath: "/Contents/a.mp3",
        analyzePath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT")
    let data = RekordboxPDBWriter.build(tracks: [track], playlists: [])
    #expect(data.range(of: Data("/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT".utf8)) != nil)
}

@Test func bandAccumulatorSeparatesBassFromTreble() {
    func columns(frequency: Double) -> [CDJBandColumn] {
        let rate = 44_100.0
        let samples = (0..<Int(rate)).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        var accumulator = CDJBandAccumulator(sampleRate: rate)
        samples.withUnsafeBufferPointer { accumulator.push($0) }
        return accumulator.finish()
    }
    let bass = columns(frequency: 60)
    #expect(bass.count == 150)
    let settled = bass[75]
    #expect(settled.low > settled.mid && settled.low > settled.high)

    let treble = columns(frequency: 9_000)
    #expect(treble[75].high > treble[75].mid && treble[75].high > treble[75].low)
    #expect(treble[75].peak > 100)  // 0.5 of full scale
}

@Test func bandAccumulatorHandlesOddSampleRatesAndSplitBuffers() {
    var whole = CDJBandAccumulator(sampleRate: 48_000)
    var split = CDJBandAccumulator(sampleRate: 48_000)
    let samples = (0..<48_000).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
    samples.withUnsafeBufferPointer { whole.push($0) }
    samples.withUnsafeBufferPointer {
        split.push(UnsafeBufferPointer(rebasing: $0[0..<12_345]))
        split.push(UnsafeBufferPointer(rebasing: $0[12_345...]))
    }
    #expect(whole.finish() == split.finish())
    #expect(whole.columns.count == 150)
}
