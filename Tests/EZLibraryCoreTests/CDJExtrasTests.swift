// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EZLibraryCore

private func pngData(width: Int, height: Int, red: UInt8 = 200) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(red) / 255, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func size(ofImage data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

// MARK: - Keys

@Test func keysAreReadFromCamelotClassicAndSpelledForms() {
    #expect(CDJMusicalKey.classicName(from: "8A") == "Am")
    #expect(CDJMusicalKey.classicName(from: "8B") == "C")
    #expect(CDJMusicalKey.classicName(from: "12a") == "Dbm")
    #expect(CDJMusicalKey.classicName(from: "1A") == "Abm")
    #expect(CDJMusicalKey.classicName(from: "C#m") == "Dbm")
    #expect(CDJMusicalKey.classicName(from: "G#") == "Ab")
    #expect(CDJMusicalKey.classicName(from: "Am") == "Am")
    #expect(CDJMusicalKey.classicName(from: "A min") == "Am")
    #expect(CDJMusicalKey.classicName(from: "F# major") == "F#")
    #expect(CDJMusicalKey.classicName(from: "Bbm") == "Bbm")
    #expect(CDJMusicalKey.classicName(from: "A#") == "Bb")
    #expect(CDJMusicalKey.classicName(from: "Db") == "Db")
    #expect(CDJMusicalKey.classicName(from: "13A") == nil)
    #expect(CDJMusicalKey.classicName(from: "nonsense") == nil)
    #expect(CDJMusicalKey.classicName(from: nil) == nil)
    #expect(CDJMusicalKey.classicName(from: "  ") == nil)
}

// MARK: - DEVSETTING.DAT

@Test func deviceSettingsFileMatchesTheDocumentedLayout() {
    let data = CDJDeviceSettingsFile.data()
    #expect(data.count == 140)
    #expect(Array(data[0..<4]) == [0x60, 0, 0, 0])
    #expect(String(decoding: data[4..<14], as: UTF8.self) == "PIONEER DJ")
    #expect(String(decoding: data[0x24..<0x2d], as: UTF8.self) == "rekordbox")
    #expect(String(decoding: data[0x44..<0x4a], as: UTF8.self) == "7.2.11")
    #expect(Array(data[0x64..<0x68]) == [32, 0, 0, 0])
    let body = Array(data[0x68..<0x88])
    #expect(Array(body[0..<4]) == [0x78, 0x56, 0x34, 0x12])
    let stored = UInt16(data[0x88]) | UInt16(data[0x89]) << 8
    #expect(stored == CDJDeviceSettingsFile.crc16XModem(body))
    // The standard CRC-16/XMODEM check value.
    #expect(CDJDeviceSettingsFile.crc16XModem(Array("123456789".utf8)) == 0x31C3)
}

// MARK: - Lock

@Test func aSecondExportToTheSameStickIsHeldOff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var first: CDJExportLock? = try CDJExportLock(volume: directory)
    #expect(first != nil)
    #expect(throws: CDJExportError.self) { try CDJExportLock(volume: directory) }
    first = nil
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(CDJExportLock.fileName).path))
    _ = try CDJExportLock(volume: directory)
}

@Test func differentSticksDoNotBlockEachOther() throws {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cdjlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    let one = try folder(), two = try folder()
    defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
    let first = try CDJExportLock(volume: one)
    let second = try CDJExportLock(volume: two)
    withExtendedLifetime((first, second)) {}
}

// MARK: - Artwork images

@Test func coversAreCroppedToSquaresAtBothSizes() throws {
    let rendered = try #require(CDJArtwork.render(pngData(width: 600, height: 400)))
    #expect(size(ofImage: rendered.small)! == (80, 80))
    #expect(size(ofImage: rendered.medium)! == (240, 240))
    #expect(CDJArtwork.render(Data("not an image".utf8)) == nil)
}

@Test func artworkPathsFollowTheTwentyPerFolderLayout() {
    #expect(CDJArtworkImage.path(forID: 1, root: "PIONEER") == "/PIONEER/Artwork/00001/a1.jpg")
    #expect(CDJArtworkImage.path(forID: 19, root: "PIONEER") == "/PIONEER/Artwork/00001/a19.jpg")
    #expect(CDJArtworkImage.path(forID: 20, root: "PIONEER") == "/PIONEER/Artwork/00002/a20.jpg")
    #expect(CDJArtworkImage.path(forID: 3, root: ".PIONEER") == "/.PIONEER/Artwork/00001/a3.jpg")
}

@Test func eachImageWritesFourFiles() throws {
    let rendered = try #require(CDJArtwork.render(pngData(width: 100, height: 100)))
    let image = CDJArtworkImage(id: 21, path: CDJArtworkImage.path(forID: 21, root: "PIONEER"),
                                small: rendered.small, medium: rendered.medium)
    #expect(image.files.map(\.relative) == [
        "PIONEER/Artwork/00002/a21.jpg", "PIONEER/Artwork/00002/a21_m.jpg",
        "PIONEER/Artwork/00002/b21.jpg", "PIONEER/Artwork/00002/b21_m.jpg"
    ])
    #expect(image.files[0].data == image.files[2].data)
    #expect(image.files[1].data == image.files[3].data)
}

@Test func identicalCoversShareOneImageAndTracksWithoutOneAreSkipped() async {
    let red = pngData(width: 50, height: 50, red: 250)
    let blue = pngData(width: 50, height: 50, red: 10)
    let urls = (1...4).map { URL(fileURLWithPath: "/tmp/t\($0).mp3") }
    let result = await CDJArtwork.collect(
        for: [(1, urls[0]), (2, urls[1]), (3, urls[2]), (4, urls[3])], root: "PIONEER",
        reader: { url in
            switch url.lastPathComponent {
            case "t1.mp3", "t3.mp3": return red
            case "t2.mp3": return blue
            default: return nil
            }
        })
    #expect(result.images.map(\.id) == [1, 2])
    #expect(result.byTrack[1]?.id == 1)
    #expect(result.byTrack[3]?.id == 1)
    #expect(result.byTrack[2]?.id == 2)
    #expect(result.byTrack[4] == nil)
}

// MARK: - Databases

@Test func exportPdbCarriesKeysAndArtwork() throws {
    let tracks = [
        CDJExportTrack(id: 1, title: "One", stickPath: "/Contents/a/one.mp3", key: "Am", artworkID: 1,
                       artworkPath: "/PIONEER/Artwork/00001/a1.jpg"),
        CDJExportTrack(id: 2, title: "Two", stickPath: "/Contents/a/two.mp3", key: "Am", artworkID: 1,
                       artworkPath: "/PIONEER/Artwork/00001/a1.jpg"),
        CDJExportTrack(id: 3, title: "Three", stickPath: "/Contents/a/three.mp3", key: "C")
    ]
    let file = try RekordboxPDBFile(RekordboxPDBWriter.build(tracks: tracks, playlists: []))
    #expect(try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.keys).count == 2)
    #expect(try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.artwork).count == 1)
    #expect(try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.tracks).count == 3)
}

@Test func oneLibraryCarriesKeysAndImages() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("onelib-extras-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: url) }
    let tracks = [
        CDJExportTrack(id: 1, title: "One", stickPath: "/Contents/a/one.mp3", key: "Am", artworkID: 1,
                       artworkPath: "/PIONEER/Artwork/00001/a1.jpg"),
        CDJExportTrack(id: 2, title: "Two", stickPath: "/Contents/a/two.mp3")
    ]
    try OneLibraryWriter.write(
        to: url, tracks: tracks, playlists: [], analyses: [:], deviceName: "S", createdDate: "2026-01-01",
        libraryID: 1, settings: .defaults)
    let database = try CDJSQLiteDatabase(url: url, passphrase: OneLibraryKey.passphrase(), readOnly: true)
    #expect(try database.rows("SELECT name FROM key", columns: 1).first?.first == .text("Am"))
    #expect(try database.rows("SELECT path FROM image", columns: 1).first?.first == .text("/PIONEER/Artwork/00001/a1.jpg"))
    #expect(try database.rows("SELECT key_id, image_id FROM content WHERE content_id = 1", columns: 2).first == [.int(1), .int(1)])
    #expect(try database.rows("SELECT key_id, image_id FROM content WHERE content_id = 2", columns: 2).first == [.int(0), .null])
}

// MARK: - End to end

private func makeStick() throws -> (directory: URL, stick: URL, tracks: [Track], crate: Crate) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjextras-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    var tracks: [Track] = []
    for name in ["one", "two"] {
        let file = directory.appendingPathComponent("\(name).mp3")
        try Data("audio-\(name)".utf8).write(to: file)
        var track = Track(seratoStoredPath: "p/\(name).mp3", fileURL: file, title: name, artist: "A", album: "B", duration: 3)
        track.key = name == "one" ? "8A" : nil
        tracks.append(track)
    }
    return (directory, stick, tracks, Crate(pathComponents: ["Set"], trackPaths: tracks.map(\.seratoStoredPath)))
}

private func environment(artwork: @escaping @Sendable (URL) async -> Data?) -> CDJExportEnvironment {
    var env = CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in .max })
    env.artworkReader = artwork
    return env
}

@Test func exportWritesCoversKeysAndDeviceSettingsAndCleansUpAfterItself() async throws {
    let (directory, stick, tracks, crate) = try makeStick()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cover = pngData(width: 120, height: 120)
    func run(_ reader: @escaping @Sendable (URL) async -> Data?) async throws {
        let plan = CDJSeratoExport.plan(
            crates: [crate], library: tracks, previous: CDJExportManifest.load(from: stick, root: "PIONEER"))
        _ = try await CDJSeratoExport.export(plan, to: stick, environment: environment(artwork: reader))
    }
    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: stick.appendingPathComponent(relative).path)
    }

    try await run { _ in cover }
    for name in ["a1.jpg", "a1_m.jpg", "b1.jpg", "b1_m.jpg"] { #expect(exists("PIONEER/Artwork/00001/\(name)")) }
    let settings = try Data(contentsOf: stick.appendingPathComponent("PIONEER/DEVSETTING.DAT"))
    #expect(settings == CDJDeviceSettingsFile.data())
    let database = try RekordboxPDBFile(Data(contentsOf: stick.appendingPathComponent("PIONEER/rekordbox/export.pdb")))
    #expect(try database.rowOffsets(inTable: RekordboxPDBWriter.TableType.artwork).count == 1)
    #expect(try database.rowOffsets(inTable: RekordboxPDBWriter.TableType.keys).count == 1)
    #expect(!exists(CDJExportLock.fileName))

    // The DJ's own settings file is left alone, and covers that are no longer wanted go.
    let custom = Data("djs own settings".utf8)
    try custom.write(to: stick.appendingPathComponent("PIONEER/DEVSETTING.DAT"))
    try await run { _ in nil }
    #expect(try Data(contentsOf: stick.appendingPathComponent("PIONEER/DEVSETTING.DAT")) == custom)
    #expect(!exists("PIONEER/Artwork/00001/a1.jpg"))
    #expect(!exists("PIONEER/Artwork/00001/b1_m.jpg"))
}

@Test func exportingToAStickThatIsAlreadyBeingWrittenIsRefused() async throws {
    let (directory, stick, tracks, crate) = try makeStick()
    defer { try? FileManager.default.removeItem(at: directory) }
    let held = try CDJExportLock(volume: stick)
    let plan = CDJSeratoExport.plan(crates: [crate], library: tracks)
    await #expect(throws: CDJExportError.self) {
        _ = try await CDJSeratoExport.export(plan, to: stick, environment: environment(artwork: { _ in nil }))
    }
    withExtendedLifetime(held) {}
    #expect(!FileManager.default.fileExists(atPath: stick.appendingPathComponent("PIONEER").path))
}

// MARK: - Reading covers out of files

private func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

@Test func flacPicturesPreferTheFrontCover() throws {
    func picture(type: Int, bytes: [UInt8]) -> [UInt8] {
        be32(type) + be32(10) + Array("image/jpg".utf8) + [0] + be32(0) + [UInt8](repeating: 0, count: 16)
            + be32(bytes.count) + bytes
    }
    func block(_ type: UInt8, last: Bool, _ body: [UInt8]) -> [UInt8] {
        [type | (last ? 0x80 : 0), UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }
    let bytes = Array("fLaC".utf8) + block(6, last: false, picture(type: 4, bytes: [1, 1, 1]))
        + block(6, last: true, picture(type: 3, bytes: [9, 9]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).flac")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(bytes).write(to: url)
    #expect(CDJArtwork.flacPicture(at: url) == Data([9, 9]))
}

@Test func coversInTheID3ChunkOfAiffAndWavAreFound() throws {
    let image = Data(pngData(width: 8, height: 8))
    let frame = [UInt8](ID3ArtworkCodec.apicFrame(for: ID3Artwork(mimeType: "image/png", imageData: image)))
    let size = frame.count
    let syncsafe: [UInt8] = [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
    let tag = Array("ID3".utf8) + [4, 0, 0] + syncsafe + frame

    func file(form: String, bigEndian: Bool) -> Data {
        func u32(_ value: Int) -> [UInt8] { bigEndian ? be32(value) : be32(value).reversed() }
        let body = (bigEndian ? Array("AIFF".utf8) : Array("WAVE".utf8))
            + Array("ID3 ".utf8) + u32(tag.count) + tag + (tag.count % 2 == 1 ? [0] : [])
        return Data(Array(form.utf8) + u32(body.count) + body)
    }
    for (form, bigEndian, ext) in [("FORM", true, "aiff"), ("RIFF", false, "wav")] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try file(form: form, bigEndian: bigEndian).write(to: url)
        #expect(CDJArtwork.chunkedID3Picture(at: url, form: form, bigEndian: bigEndian) == image)
    }
}

// MARK: - MP3 conversion

private func writeHiResWAV(to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000.0, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames: AVAudioFrameCount = 48_000
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for frame in 0..<Int(frames) { data[channel][frame] = 0.4 * Float(sin(Double(frame) * 0.05)) }
    }
    try file.write(from: buffer)
}

/// A stand-in `ffmpeg`: copies the file after `-i` to the last argument, or fails when told to.
private func makeFakeEncoder(in directory: URL, succeeds: Bool = true) throws -> URL {
    let url = directory.appendingPathComponent("fake-ffmpeg-\(UUID().uuidString)")
    let script = succeeds
        ? "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in -i) in=\"$2\";; esac; last=\"$1\"; shift; done\ncp \"$in\" \"$last\"\n"
        : "#!/bin/sh\necho boom >&2\nexit 1\n"
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test func withAnEncoderConvertedTracksBecomeMP3() {
    let probe = CDJAudioProbe(sampleRate: 96_000, channels: 2, bitDepth: 24, isIntegerPCM: true, durationSeconds: 200)
    let mp3 = CDJExportOptions(mp3Encoder: URL(fileURLWithPath: "/usr/bin/true"))
    #expect(CDJAudioCompatibility.decide(type: .wav, probe: probe, fileSize: 1_000, options: mp3) == .convert(.mp3))
    #expect(CDJAudioCompatibility.decide(type: .flac, probe: probe, fileSize: 1_000, options: mp3) == .convert(.mp3))
    #expect(CDJAudioCompatibility.decide(type: .flac, probe: probe, fileSize: 1_000, options: CDJExportOptions()) == .convert(.wav))
    // Files that already play are still copied untouched.
    let fine = CDJAudioProbe(sampleRate: 44_100, channels: 2, bitDepth: 16, isIntegerPCM: true, durationSeconds: 200)
    #expect(CDJAudioCompatibility.decide(type: .wav, probe: fine, fileSize: 1_000, options: mp3) == .copy)
    #expect(CDJAudioConversion.mp3.fileType == .mp3)
    #expect(CDJAudioConversion.mp3.pathExtension == "mp3")
    #expect(CDJAudioConversion.mp3.estimatedBytes(durationSeconds: 100) < CDJAudioConversion.wav.estimatedBytes(durationSeconds: 100) / 3)
}

@Test func exportConvertsToMP3ThroughTheEncoder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjmp3-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("hires.wav")
    try writeHiResWAV(to: source)
    let track = Track(seratoStoredPath: "p/hires.wav", fileURL: source, title: "Hi", artist: "A", album: "B", duration: 0.5)
    let crate = Crate(pathComponents: ["Set"], trackPaths: [track.seratoStoredPath])
    let encoder = try makeFakeEncoder(in: directory)

    let plan = CDJSeratoExport.plan(crates: [crate], library: [track], options: CDJExportOptions(mp3Encoder: encoder))
    let item = try #require(plan.items.first)
    #expect(item.conversion == .mp3)
    #expect(item.export.fileType == .mp3)
    #expect(item.export.bitrate == 320)
    #expect(item.export.stickPath.hasSuffix(".mp3"))

    let result = try await CDJSeratoExport.export(plan, to: stick, environment: environment(artwork: { _ in nil }))
    #expect(result.filesCopied == 1)
    #expect(FileManager.default.fileExists(atPath: stick.appendingPathComponent(String(item.export.stickPath.dropFirst())).path))

    // Switching the encoder off changes the recipe, so the copy is replaced by a WAV.
    let again = CDJSeratoExport.plan(
        crates: [crate], library: [track], previous: CDJExportManifest.load(from: stick, root: "PIONEER"))
    #expect(again.items.first?.conversion == .wav)
    #expect(again.removals.count == 1)
}

@Test func anEncoderThatFailsLeavesTheStickUntouched() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjmp3-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("hires.wav")
    try writeHiResWAV(to: source)
    let track = Track(seratoStoredPath: "p/hires.wav", fileURL: source, title: "Hi", artist: "A", album: "B", duration: 0.5)
    let crate = Crate(pathComponents: ["Set"], trackPaths: [track.seratoStoredPath])
    let encoder = try makeFakeEncoder(in: directory, succeeds: false)
    let plan = CDJSeratoExport.plan(crates: [crate], library: [track], options: CDJExportOptions(mp3Encoder: encoder))

    await #expect(throws: (any Error).self) {
        _ = try await CDJSeratoExport.export(plan, to: stick, environment: environment(artwork: { _ in nil }))
    }
    #expect(!FileManager.default.fileExists(atPath: stick.appendingPathComponent("PIONEER").path))
    #expect(!FileManager.default.fileExists(atPath: stick.appendingPathComponent("Contents").path))
}

@Test func theRealFFmpegEncodesA320kStereoMP3WhenItIsInstalled() throws {
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjmp3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("hires.wav")
    let output = directory.appendingPathComponent("out.mp3")
    try writeHiResWAV(to: source)
    try CDJAudioConverter.convert(from: source, to: output, as: .mp3, encoder: URL(fileURLWithPath: path))
    let probe = try #require(CDJAudioProbe.read(output))
    #expect(probe.sampleRate == 44_100)
    #expect(probe.channels == 2)
    #expect(abs(probe.durationSeconds - 0.5) < 0.1)
}
