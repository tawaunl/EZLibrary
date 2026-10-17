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

@Test func datFileHasConsistentSectionsAndBeatGrid() {
    let analysis = SeratoTrackAnalysis(
        cues: [.init(index: 0, positionMs: 2_000, color: .init(red: 1, green: 2, blue: 3), name: "Intro")],
        loops: [.init(index: 0, startMs: 4_000, endMs: 8_000, color: .init(red: 0, green: 0, blue: 0), name: "")])
    let input = CDJAnalysisInput(
        stickPath: "/Contents/A/B/x.mp3", durationMs: 10_000,
        beats: [CDJBeat(beatNumber: 1, tempo: 12_000, timeMs: 500)],
        analysis: analysis, peaks: (0..<1000).map { Float($0) / 1000 })
    let dat = RekordboxAnalysisWriter.datFile(input)

    #expect(String(decoding: dat.prefix(4), as: UTF8.self) == "PMAI")
    #expect(Int(dat.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) == dat.count)
    let found = sections(in: dat)
    #expect(found.map(\.tag) == ["PPTH", "PQTZ", "PWAV", "PWV2", "PCOB", "PCOB"])
    #expect(found.last.map { $0.offset + $0.length } == dat.count)
    #expect(found[2].length - found[2].header == 400)
    #expect(found[3].length - found[3].header == 100)
    // One memory loop, one hot cue.
    #expect(found[4].length - found[4].header == 0x38)
    #expect(found[5].length - found[5].header == 0x38)
}

@Test func extFileCarriesColouredCuesAndScrollWaveform() {
    let input = CDJAnalysisInput(
        stickPath: "/Contents/A/B/x.mp3", durationMs: 4_000,
        analysis: SeratoTrackAnalysis(cues: [
            .init(index: 1, positionMs: 100, color: .init(red: 9, green: 8, blue: 7), name: "Hi")]),
        peaks: [0.1, 0.9, 0.5])
    let ext = RekordboxAnalysisWriter.extFile(input)
    let found = sections(in: ext)
    #expect(found.map(\.tag) == ["PPTH", "PCOB", "PCOB", "PCO2", "PCO2", "PWV3"])
    #expect(found[5].length - found[5].header == 600)  // 4 s at 150 columns/s
    let hotCues = ext.subdata(in: found[4].offset..<(found[4].offset + found[4].length))
    #expect(hotCues.range(of: Data([0, 9, 8, 7])) != nil)
}

@Test func analysisFilesAreWrittenForTrackWithoutAudio() async throws {
    let volume = FileManager.default.temporaryDirectory.appendingPathComponent("cdjvol-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: volume) }
    let export = CDJExportTrack(
        id: 300, title: "x", durationSeconds: 5, stickPath: "/Contents/A/B/x.mp3",
        analyzePath: CDJSeratoExport.analyzePath(forTrackID: 300))
    #expect(export.analyzePath == "/PIONEER/USBANLZ/P001/0000012C/ANLZ0000.DAT")
    let item = CDJExportPlan.Item(source: URL(fileURLWithPath: "/nonexistent/x.flac"), export: export)

    let hadSeratoData = try await CDJSeratoExport.writeAnalysis(for: item, volume: volume)
    #expect(hadSeratoData == false)
    let base = volume.appendingPathComponent("PIONEER/USBANLZ/P001/0000012C")
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("ANLZ0000.DAT").path))
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("ANLZ0000.EXT").path))
}

@Test func pdbTrackRowPointsAtAnalysisFiles() {
    let track = CDJExportTrack(
        id: 1, title: "t", stickPath: "/Contents/a.mp3",
        analyzePath: "/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT")
    let data = RekordboxPDBWriter.build(tracks: [track], playlists: [])
    #expect(data.range(of: Data("/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT".utf8)) != nil)
}
