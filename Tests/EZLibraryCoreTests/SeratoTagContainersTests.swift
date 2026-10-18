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

private func le32(_ value: UInt32) -> [UInt8] { be32(value).reversed() }

/// A `Serato Markers2` payload holding one cue at slot 3 / 12.5 s.
private let markers2Payload: [UInt8] = {
    let cue: [UInt8] = [0x00, 0x03] + be32(12_500) + [0x00, 0x10, 0x20, 0x30, 0x00, 0x00] + Array("Hook".utf8) + [0x00]
    var blob: [UInt8] = [0x01, 0x01]
    blob += Array("CUE".utf8) + [0x00] + be32(UInt32(cue.count)) + cue
    return [0x01, 0x01] + Array(Data(blob).base64EncodedString().utf8)
}()

private let beatgridPayload: [UInt8] =
    [0x01, 0x00] + be32(1) + be32(Float(0.25).bitPattern) + be32(Float(126).bitPattern) + [0x00]

private func id3Tag() -> [UInt8] {
    func geob(_ description: String, _ payload: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [0x00] + Array("application/octet-stream".utf8) + [0x00, 0x00]
            + Array(description.utf8) + [0x00] + payload
        return Array("GEOB".utf8) + be32(UInt32(body.count)) + [0, 0] + body
    }
    let frames = geob("Serato Markers2", markers2Payload) + geob("Serato BeatGrid", beatgridPayload)
    let size = UInt32(frames.count)
    let syncsafe: [UInt8] = [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
                             UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
    return Array("ID3".utf8) + [0x03, 0x00, 0x00] + syncsafe + frames
}

private func write(_ bytes: [UInt8], ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("serato-\(UUID().uuidString).\(ext)")
    try Data(bytes).write(to: url)
    return url
}

private func expectFullAnalysis(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    let analysis = SeratoAnalysisTagReader.analysis(forFileAt: url)
    #expect(analysis?.cues.count == 1, sourceLocation: sourceLocation)
    #expect(analysis?.cues.first?.index == 3, sourceLocation: sourceLocation)
    #expect(analysis?.cues.first?.positionMs == 12_500, sourceLocation: sourceLocation)
    #expect(analysis?.cues.first?.name == "Hook", sourceLocation: sourceLocation)
    #expect(analysis?.beatgrid.first?.bpm == 126, sourceLocation: sourceLocation)
}

@Test func readsSeratoDataFromMP3() throws {
    let url = try write(id3Tag() + [UInt8](repeating: 0, count: 64), ext: "mp3")
    defer { try? FileManager.default.removeItem(at: url) }
    expectFullAnalysis(url)
}

@Test func readsSeratoDataFromAIFFChunk() throws {
    let tag = id3Tag()
    let padding: [UInt8] = tag.count % 2 == 1 ? [0] : []
    let comm = Array("COMM".utf8) + be32(18) + [UInt8](repeating: 0, count: 18)
    let chunk = Array("ID3 ".utf8) + be32(UInt32(tag.count)) + tag + padding
    let body = Array("AIFF".utf8) + comm + chunk
    let url = try write(Array("FORM".utf8) + be32(UInt32(body.count)) + body, ext: "aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    expectFullAnalysis(url)
}

@Test func readsSeratoDataFromWAVChunk() throws {
    let tag = id3Tag()
    let padding: [UInt8] = tag.count % 2 == 1 ? [0] : []
    let fmt = Array("fmt ".utf8) + le32(16) + [UInt8](repeating: 0, count: 16)
    let chunk = Array("id3 ".utf8) + le32(UInt32(tag.count)) + tag + padding
    let body = Array("WAVE".utf8) + fmt + chunk
    let url = try write(Array("RIFF".utf8) + le32(UInt32(body.count)) + body, ext: "wav")
    defer { try? FileManager.default.removeItem(at: url) }
    expectFullAnalysis(url)
}

@Test func readsSeratoDataFromFLACPictureBlocks() throws {
    func picture(_ description: String, _ data: [UInt8], isLast: Bool) -> [UInt8] {
        let body = be32(0) + be32(24) + Array("application/octet-stream".utf8)
            + be32(UInt32(description.utf8.count)) + Array(description.utf8)
            + [UInt8](repeating: 0, count: 16) + be32(UInt32(data.count)) + data
        return [isLast ? 0x86 : 0x06] + Array(be32(UInt32(body.count)).dropFirst()) + body
    }
    let streamInfo: [UInt8] = [0x00, 0x00, 0x00, 0x22] + [UInt8](repeating: 0, count: 34)
    let bytes = Array("fLaC".utf8) + streamInfo
        + picture("Serato Markers2", markers2Payload, isLast: false)
        + picture("Serato BeatGrid", beatgridPayload, isLast: true)
    let url = try write(bytes, ext: "flac")
    defer { try? FileManager.default.removeItem(at: url) }
    expectFullAnalysis(url)
}

@Test func readsSeratoDataFromM4AFreeformAtoms() throws {
    func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(UInt32(payload.count + 8)) + Array(type.utf8) + payload
    }
    func freeform(_ name: String, _ value: [UInt8]) -> [UInt8] {
        box("----",
            box("mean", [0, 0, 0, 0] + Array("com.serato.dj".utf8))
            + box("name", [0, 0, 0, 0] + Array(name.utf8))
            // Stored base64-wrapped, as Serato does outside ID3.
            + box("data", [0, 0, 0, 1, 0, 0, 0, 0] + Array(Data(value).base64EncodedString().utf8)))
    }
    let ilst = box("ilst", freeform("markersv2", markers2Payload) + freeform("beatgrid", beatgridPayload))
    let moov = box("moov", box("udta", box("meta", [0, 0, 0, 0] + ilst)))
    let url = try write(box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0]) + moov + box("mdat", [0, 0]), ext: "m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    expectFullAnalysis(url)
}

@Test func unanalysedFilesAndUnknownTypes() throws {
    let wav = try write(Array("RIFF".utf8) + le32(4) + Array("WAVE".utf8), ext: "wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    #expect(SeratoAnalysisTagReader.analysis(forFileAt: wav)?.isEmpty == true)
    #expect(SeratoAnalysisTagReader.analysis(forFileAt: URL(fileURLWithPath: "/x/y.ogg")) == nil)
    #expect(SeratoAnalysisTagReader.analysis(forFileAt: URL(fileURLWithPath: "/nonexistent/y.flac"))?.isEmpty == true)
}
