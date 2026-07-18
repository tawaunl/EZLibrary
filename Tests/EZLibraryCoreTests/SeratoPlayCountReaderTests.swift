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

/// Builds a `TXXX` frame body: encoding byte, null-terminated description, value.
private func txxxLatin1(description: String, value: String) -> [UInt8] {
    [0x00] + Array(description.utf8) + [0x00] + Array(value.utf8)
}

private func txxxUTF8(description: String, value: String) -> [UInt8] {
    [0x03] + Array(description.utf8) + [0x00] + Array(value.utf8)
}

@Test func readsSeratoPlayCountFromTXXXFrame() {
    let tag = id3v24Tag(id3Frame("TXXX", txxxLatin1(description: "SERATO_PLAYCOUNT", value: "7")))
    #expect(ID3ArtworkCodec.userTextValue(fromID3TagBytes: tag, description: "SERATO_PLAYCOUNT") == "7")
}

@Test func userTextValueMatchesDescriptionCaseInsensitively() {
    let tag = id3v24Tag(id3Frame("TXXX", txxxUTF8(description: "Serato_PlayCount", value: "42")))
    #expect(ID3ArtworkCodec.userTextValue(fromID3TagBytes: tag, description: "SERATO_PLAYCOUNT") == "42")
}

@Test func userTextValueReturnsNilForMissingDescription() {
    let tag = id3v24Tag(id3Frame("TXXX", txxxLatin1(description: "SOMETHING_ELSE", value: "9")))
    #expect(ID3ArtworkCodec.userTextValue(fromID3TagBytes: tag, description: "SERATO_PLAYCOUNT") == nil)
}

@Test func playCountReaderParsesTaggedMP3File() throws {
    let tag = id3v24Tag(id3Frame("TXXX", txxxLatin1(description: "SERATO_PLAYCOUNT", value: "13")))
    var fileData = tag
    // Minimal fake MPEG audio payload after the tag.
    fileData.append(Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0x00, count: 64)))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("playcount-\(UUID().uuidString).mp3")
    try fileData.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(SeratoPlayCountReader.playCount(forFileAt: url) == 13)
}

@Test func playCountReaderReturnsNilWhenTagMissing() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("noplaycount-\(UUID().uuidString).mp3")
    try Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0x00, count: 64)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(SeratoPlayCountReader.playCount(forFileAt: url) == nil)
}

@Test func playCountReaderIgnoresNonMP3Files() throws {
    let tag = id3v24Tag(id3Frame("TXXX", txxxLatin1(description: "SERATO_PLAYCOUNT", value: "5")))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("playcount-\(UUID().uuidString).flac")
    try tag.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(SeratoPlayCountReader.playCount(forFileAt: url) == nil)
}
