import Foundation
import Testing
@testable import EZLibraryCore

private func syncsafe(_ v: Int) -> [UInt8] {
    [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
}

private func id3Frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + syncsafe(body.count) + [0x00, 0x00] + body
}

private func id3v24Tag(_ frames: [UInt8]) -> Data {
    Data(Array("ID3".utf8) + [0x04, 0x00, 0x00] + syncsafe(frames.count) + frames)
}

private let fakeJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0xAB, count: 32) + [0xFF, 0xD9]

private func apicFrameBytes() -> [UInt8] {
    var body: [UInt8] = [0x00] // latin1
    body += Array("image/jpeg".utf8) + [0x00]
    body += [0x03] // front cover
    body += [0x00] // empty description
    body += fakeJPEG
    return id3Frame("APIC", body)
}

@Test func extractsEmbeddedFrontCover() {
    let tag = id3v24Tag(id3Frame("TIT2", [0x03] + Array("Title".utf8)) + apicFrameBytes())
    let art = ID3ArtworkCodec.extractArtwork(fromID3TagBytes: tag)
    #expect(art != nil)
    #expect(art?.mimeType == "image/jpeg")
    #expect(art?.pictureType == 0x03)
    #expect(art.map { Array($0.imageData) } == fakeJPEG)
}

@Test func preservesOtherFramesButNotOverwrittenOrArtwork() {
    let frames = id3Frame("TIT2", [0x03] + Array("Old".utf8))
        + id3Frame("TRCK", [0x03] + Array("5/12".utf8))
        + apicFrameBytes()
    let tag = id3v24Tag(frames)

    let preserved = ID3ArtworkCodec.preservedFrames(
        fromID3TagBytes: tag,
        excludingFrameIDs: ["TIT2", "TPE1", "TALB", "TCON", "TKEY", "TBPM", "TYER", "TDRC", "TDAT", "COMM"]
    )
    let preservedString = String(decoding: preserved, as: UTF8.self)
    #expect(preservedString.contains("TRCK"))
    #expect(!preservedString.contains("TIT2"))
    #expect(!preservedString.contains("APIC"))
}

@Test func artworkSurvivesTagRebuild() {
    let originalTag = id3v24Tag(id3Frame("TIT2", [0x03] + Array("Old".utf8)) + apicFrameBytes())
    let art = ID3ArtworkCodec.extractArtwork(fromID3TagBytes: originalTag)
    #expect(art != nil)

    var rebuilt = Data()
    rebuilt.append(Data(id3Frame("TIT2", [0x03] + Array("New".utf8))))
    rebuilt.append(ID3ArtworkCodec.apicFrame(for: art!))
    let rebuiltTag = id3v24Tag([UInt8](rebuilt))

    let art2 = ID3ArtworkCodec.extractArtwork(fromID3TagBytes: rebuiltTag)
    #expect(art2.map { Array($0.imageData) } == fakeJPEG)
}

@Test func mimeSniffingDetectsJpegAndPng() {
    #expect(ID3ArtworkCodec.mimeType(forImageData: Data(fakeJPEG)) == "image/jpeg")
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    #expect(ID3ArtworkCodec.mimeType(forImageData: Data(png)) == "image/png")
}

@Test func tagWithoutArtworkReturnsNil() {
    let tag = id3v24Tag(id3Frame("TIT2", [0x03] + Array("Title".utf8)))
    #expect(ID3ArtworkCodec.extractArtwork(fromID3TagBytes: tag) == nil)
}

// MARK: - Serato cue-point (GEOB) preservation

private func geobBody(name: String, payload: [UInt8]) -> [UInt8] {
    [0x00] // ISO-8859-1 encoding
        + Array("application/octet-stream".utf8) + [0x00] // MIME
        + [0x00] // empty filename
        + Array(name.utf8) + [0x00] // content description (e.g. "Serato Markers2")
        + payload
}

@Test func preservesSeratoGeobCueFrame() {
    let body = geobBody(name: "Serato Markers2", payload: [0xDE, 0xAD, 0xBE, 0xEF])
    let tag = id3v24Tag(id3Frame("TIT2", [0x03] + Array("Old".utf8)) + id3Frame("GEOB", body))

    let preserved = ID3ArtworkCodec.preservedFrames(fromID3TagBytes: tag, excludingFrameIDs: ["TIT2"])
    let text = String(decoding: preserved, as: UTF8.self)
    #expect(text.contains("GEOB"))
    #expect(text.contains("Serato Markers2"))
}

@Test func preservesGeobThroughTagLevelUnsynchronisation() {
    // Logical payload ends with two 0xFF bytes; unsynchronisation inserts a
    // 0x00 after each 0xFF, and the frame size counts those inserted bytes.
    let prefix = geobBody(name: "Serato Markers2", payload: [])
    let unsynced = prefix + [0xFF, 0x00, 0xFF, 0x00, 0x01]
    let frame = Array("GEOB".utf8) + syncsafe(unsynced.count) + [0x00, 0x00] + unsynced
    // Header flags 0x80 = whole-tag unsynchronisation.
    let tag = Data(Array("ID3".utf8) + [0x04, 0x00, 0x80] + syncsafe(frame.count) + frame)

    let preserved = ID3ArtworkCodec.preservedFrames(fromID3TagBytes: tag, excludingFrameIDs: [])
    let text = String(decoding: preserved, as: UTF8.self)
    #expect(text.contains("Serato Markers2"))

    // The inserted 0x00s must be gone, restoring the original 0xFF 0xFF pair.
    let bytes = Array(preserved)
    let restoredDoubleFF = (0..<max(0, bytes.count - 1)).contains { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xFF }
    #expect(restoredDoubleFF)
}

@Test func preservesGeobWithDataLengthIndicator() {
    let payload = geobBody(name: "Serato Markers2", payload: [0x01, 0x02, 0x03])
    let frameData = syncsafe(payload.count) + payload // 4-byte data-length indicator, then data
    // Format flags 0x01 = data-length indicator present.
    let frame = Array("GEOB".utf8) + syncsafe(frameData.count) + [0x00, 0x01] + frameData
    let tag = Data(Array("ID3".utf8) + [0x04, 0x00, 0x00] + syncsafe(frame.count) + frame)

    let preserved = ID3ArtworkCodec.preservedFrames(fromID3TagBytes: tag, excludingFrameIDs: [])
    let text = String(decoding: preserved, as: UTF8.self)
    #expect(text.contains("GEOB"))
    #expect(text.contains("Serato Markers2"))
}

