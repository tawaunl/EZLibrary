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
import Foundation
import Testing
@testable import EZLibraryCore

/// Writes a short sine tone in the given PCM shape, for conversion tests.
private func writeTone(
    to url: URL, sampleRate: Double, channels: Int, bitDepth: Int, isFloat: Bool = false,
    bigEndian: Bool = false, seconds: Double = 1
) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: isFloat,
        AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<channels {
        for frame in 0..<Int(frames) {
            data[channel][frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
    }
    try file.write(from: buffer)
}

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cdjaudio-\(UUID().uuidString)-\(name)")
}

@Test func conversionProducesSixteenBitStereo44k() throws {
    let source = scratch("hires.wav")
    let output = scratch("out.wav")
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
    try writeTone(to: source, sampleRate: 96_000, channels: 2, bitDepth: 24)

    try CDJAudioConverter.convert(from: source, to: output, as: .wav)
    let probe = try #require(CDJAudioProbe.read(output))
    #expect(probe.sampleRate == 44_100)
    #expect(probe.channels == 2)
    #expect(probe.bitDepth == 16)
    #expect(probe.isIntegerPCM)
    #expect(abs(probe.durationSeconds - 1) < 0.05)
}

@Test func monoSourcesBecomeStereoAndAIFFIsBigEndian() throws {
    let source = scratch("mono.wav")
    let output = scratch("out.aiff")
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
    try writeTone(to: source, sampleRate: 32_000, channels: 1, bitDepth: 16)

    try CDJAudioConverter.convert(from: source, to: output, as: .aiff)
    let probe = try #require(CDJAudioProbe.read(output))
    #expect(probe.channels == 2)
    #expect(probe.sampleRate == 44_100)
    #expect(String(decoding: try Data(contentsOf: output).prefix(4), as: UTF8.self) == "FORM")
    // Both channels carry the tone, not silence on one side.
    let file = try AVAudioFile(forReading: output)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let peaks = (0..<2).map { channel in (0..<Int(buffer.frameLength)).map { abs(data[channel][$0]) }.max() ?? 0 }
    #expect(peaks.allSatisfy { $0 > 0.3 })
}

@Test func decisionsFollowTheCompatibilityRules() {
    func probe(rate: Double = 44_100, channels: Int = 2, depth: Int = 16, integer: Bool = true, seconds: Double = 200)
        -> CDJAudioProbe {
        CDJAudioProbe(sampleRate: rate, channels: channels, bitDepth: depth, isIntegerPCM: integer, durationSeconds: seconds)
    }
    let maximum = CDJExportOptions()
    func decide(_ type: CDJFileType, _ probe: CDJAudioProbe?, size: Int = 1_000, _ options: CDJExportOptions = maximum)
        -> CDJAudioDecision {
        CDJAudioCompatibility.decide(type: type, probe: probe, fileSize: size, options: options)
    }

    #expect(decide(.mp3, probe()) == .copy)
    #expect(decide(.mp3, probe(rate: 48_000)) == .copy)
    #expect(decide(.mp3, probe(rate: 22_050)) == .convert(.wav))
    #expect(decide(.mp3, nil) == .copy)
    #expect(decide(.wav, probe(depth: 24, integer: true)) == .copy)
    #expect(decide(.wav, probe(rate: 96_000, depth: 24)) == .convert(.wav))
    #expect(decide(.wav, probe(depth: 32, integer: false)) == .convert(.wav))
    #expect(decide(.aiff, probe(rate: 88_200)) == .convert(.aiff))
    #expect(decide(.flac, probe()) == .convert(.wav))
    #expect(decide(.m4a, probe()) == .convert(.wav))
    #expect(decide(.flac, nil) != .copy)

    // Surround and over-size files are refused rather than mangled.
    if case .refuse = decide(.wav, probe(channels: 6)) {} else { Issue.record("surround should be refused") }
    if case .refuse = decide(.mp3, probe(), size: Int(UInt32.max) + 1) {} else { Issue.record("4 GB+ should be refused") }
    if case .refuse = decide(.flac, probe(seconds: 8 * 3_600)) {} else { Issue.record("too long for a WAV") }

    // With conversion off every file is copied as it is.
    let asIs = CDJExportOptions(maximumCompatibility: false)
    #expect(decide(.flac, probe(rate: 96_000), asIs) == .copy)
    if case .refuse = decide(.wav, probe(channels: 6), asIs) {} else { Issue.record("surround is refused either way") }
}

@Test func planConvertsHiResAndLeavesCompatibleFilesAlone() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjplanaudio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hires = directory.appendingPathComponent("hires.wav")
    let fine = directory.appendingPathComponent("fine.wav")
    try writeTone(to: hires, sampleRate: 96_000, channels: 2, bitDepth: 24)
    try writeTone(to: fine, sampleRate: 44_100, channels: 2, bitDepth: 16)
    let tracks = [
        Track(seratoStoredPath: "p/hires.wav", fileURL: hires, title: "Hi", artist: "A", album: "B"),
        Track(seratoStoredPath: "p/fine.wav", fileURL: fine, title: "Fine", artist: "A", album: "B")
    ]
    let crate = Crate(pathComponents: ["C"], trackPaths: tracks.map(\.seratoStoredPath))

    let plan = CDJSeratoExport.plan(crates: [crate], library: tracks)
    let converted = try #require(plan.items.first { $0.key == "p/hires.wav" })
    let untouched = try #require(plan.items.first { $0.key == "p/fine.wav" })
    #expect(converted.conversion == .wav)
    #expect(converted.export.stickPath.hasSuffix("hires-cdj-\(converted.export.id).wav"))
    #expect(converted.export.sampleRate == 44_100)
    #expect(converted.export.fileType == .wav)
    #expect(untouched.conversion == nil)
    #expect(untouched.export.stickPath.hasSuffix("/fine.wav"))
    #expect(plan.convertedCount == 1)

    let asIs = CDJSeratoExport.plan(crates: [crate], library: tracks, options: CDJExportOptions(maximumCompatibility: false))
    #expect(asIs.convertedCount == 0)
}

@Test func exportWritesConvertedAudioAndReusesItNextTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjconv-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hires = directory.appendingPathComponent("hires.wav")
    try writeTone(to: hires, sampleRate: 96_000, channels: 2, bitDepth: 24)
    let track = Track(seratoStoredPath: "p/hires.wav", fileURL: hires, title: "Hi", artist: "A", album: "B", duration: 1)
    let crate = Crate(pathComponents: ["C"], trackPaths: [track.seratoStoredPath])
    let environment = CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in .max })

    func plan() -> CDJExportPlan {
        CDJSeratoExport.plan(
            crates: [crate], library: [track], previous: CDJExportManifest.load(from: stick, root: "PIONEER"))
    }
    let first = try await CDJSeratoExport.export(plan(), to: stick, environment: environment)
    #expect(first.filesCopied == 1)

    let item = try #require(plan().items.first)
    let onStick = stick.appendingPathComponent(String(item.export.stickPath.dropFirst()))
    let probe = try #require(CDJAudioProbe.read(onStick))
    #expect(probe.sampleRate == 44_100 && probe.bitDepth == 16)

    // The database and manifest record the real size, not the estimate.
    let actual = try #require(try onStick.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let manifest = try #require(CDJExportManifest.load(from: stick, root: "PIONEER"))
    #expect(manifest.tracks.first?.copySize == actual)
    #expect(manifest.tracks.first?.conversion == "pcm16-44100-stereo-wav")
    let database = try RekordboxPDBFile(Data(contentsOf: stick.appendingPathComponent("PIONEER/rekordbox/export.pdb")))
    let row = try #require(try database.rowOffsets(inTable: 0).first)
    #expect(Int(database.u32(row + 0x10)) == actual)
    #expect(database.u32(row + 0x08) == 44_100)

    // Nothing changed, so nothing is converted again.
    let second = try await CDJSeratoExport.export(plan(), to: stick, environment: environment)
    #expect(second.filesCopied == 0)
    #expect(second.filesAlreadyOnStick == 1)

    // Switching conversion off replaces the converted copy with the original.
    let asIs = CDJSeratoExport.plan(
        crates: [crate], library: [track], previous: CDJExportManifest.load(from: stick, root: "PIONEER"),
        options: CDJExportOptions(maximumCompatibility: false))
    #expect(asIs.removals.count == 1)
    let third = try await CDJSeratoExport.export(asIs, to: stick, environment: environment)
    #expect(third.filesCopied == 1)
    #expect(!FileManager.default.fileExists(atPath: onStick.path))
}

@Test func exportDrawsWaveformsFromTheRealAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cdjwave-\(UUID().uuidString)")
    let stick = directory.appendingPathComponent("STICK")
    try FileManager.default.createDirectory(at: stick, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wav = directory.appendingPathComponent("tone.wav")
    try writeTone(to: wav, sampleRate: 44_100, channels: 2, bitDepth: 16, seconds: 2)
    let track = Track(seratoStoredPath: "p/tone.wav", fileURL: wav, title: "Tone", artist: "A", album: "B", duration: 2)
    let crate = Crate(pathComponents: ["C"], trackPaths: [track.seratoStoredPath])
    let environment = CDJExportEnvironment(requireVolumePath: false, detectFormat: { _ in .fat32 }, freeBytes: { _ in .max })

    _ = try await CDJSeratoExport.export(
        CDJSeratoExport.plan(crates: [crate], library: [track]), to: stick, environment: environment)
    let item = try #require(CDJSeratoExport.plan(crates: [crate], library: [track]).items.first)
    let base = String(item.export.analyzePath.dropFirst().dropLast(3))

    // 2 s of a 440 Hz tone is 300 columns, mostly low band, none silent.
    let twoEx = try Data(contentsOf: stick.appendingPathComponent(base + "2EX"))
    let marker = try #require(twoEx.range(of: Data("PWV7".utf8)))
    let header = twoEx.subdata(in: marker.lowerBound..<(marker.lowerBound + 24))
    #expect(header.suffix(12).prefix(8) == Data([0, 0, 0, 3, 0, 0, 1, 0x2C]))  // stride 3, 300 entries
    let first = [UInt8](twoEx.subdata(in: (marker.lowerBound + 24 + 3 * 100)..<(marker.lowerBound + 24 + 3 * 100 + 3)))
    #expect(first[0] > 0 && first[0] > first[2])

    let dat = try Data(contentsOf: stick.appendingPathComponent(base + "DAT"))
    try RekordboxExportVerifier.verifyAnalysis(dat, audioPath: item.export.stickPath)
}
