// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
import AVFoundation
@testable import EZLibraryCore

@Suite(.serialized)
struct AudioTrimServiceTests {

    // MARK: - Fixtures

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        TestBackupDirectory.use()
        return url
    }

    /// Renders a real MP3 with ffmpeg: `silenceSeconds` of silence followed by
    /// a 440Hz tone. Returns nil when ffmpeg isn't installed.
    private func makeTestMP3(
        at url: URL,
        silenceSeconds: Double = 0,
        toneSeconds: Double = 5
    ) throws -> URL? {
        guard let ffmpeg = AudioTrimService.ffmpegExecutablePath() else { return nil }

        let filter = silenceSeconds > 0
            ? "aevalsrc=0:d=\(silenceSeconds)[a];sine=frequency=440:duration=\(toneSeconds)[b];[a][b]concat=n=2:v=0:a=1"
            : "sine=frequency=440:duration=\(toneSeconds)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", filter,
            "-ar", "44100", "-ac", "2",
            "-c:a", "libmp3lame", "-b:a", "128k",
            url.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return url
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    // MARK: - Naming

    @Test func suggestedEditURLAppendsAnEditSuffix() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("Artist - Title.mp3")
        try Data("audio".utf8).write(to: source)

        let suggested = AudioTrimService.suggestedEditURL(for: source)

        #expect(suggested.lastPathComponent == "Artist - Title (Edit).mp3")
        #expect(suggested.deletingLastPathComponent().path == scratch.path)
    }

    @Test func suggestedEditURLStepsPastNamesAlreadyTaken() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("Artist - Title.mp3")
        try Data("audio".utf8).write(to: source)
        try Data("audio".utf8).write(to: scratch.appendingPathComponent("Artist - Title (Edit).mp3"))
        try Data("audio".utf8).write(to: scratch.appendingPathComponent("Artist - Title (Edit) 2.mp3"))

        #expect(AudioTrimService.suggestedEditURL(for: source).lastPathComponent
            == "Artist - Title (Edit) 3.mp3")
    }

    // MARK: - Validation

    @Test func rejectsARangeShorterThanTheMinimum() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("track.mp3")
        try Data("audio".utf8).write(to: source)

        #expect(throws: AudioTrimService.TrimError.self) {
            try AudioTrimService.trim(
                source: source, startSeconds: 10, endSeconds: 10.01, to: .inPlace)
        }
    }

    @Test func rejectsAMissingSourceFile() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(throws: AudioTrimService.TrimError.self) {
            try AudioTrimService.trim(
                source: scratch.appendingPathComponent("gone.mp3"),
                startSeconds: 0, endSeconds: 5, to: .inPlace)
        }
    }

    /// A save-as that would clobber an existing file must fail *before* ffmpeg
    /// runs, leaving that file byte-for-byte intact.
    @Test func refusesToOverwriteAnExistingDestination() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("track.mp3")
        try Data("audio".utf8).write(to: source)
        let destination = scratch.appendingPathComponent("taken.mp3")
        try Data("do not touch".utf8).write(to: destination)

        #expect(throws: AudioTrimService.TrimError.self) {
            try AudioTrimService.trim(
                source: source, startSeconds: 0, endSeconds: 5, to: .newFile(destination))
        }
        #expect(try Data(contentsOf: destination) == Data("do not touch".utf8))
    }

    // MARK: - Real trims

    @Test func trimsToANewFileAndLeavesTheOriginalAlone() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source.mp3")
        guard try makeTestMP3(at: source, toneSeconds: 6) != nil else { return }
        let originalBytes = try Data(contentsOf: source)

        let destination = scratch.appendingPathComponent("trimmed.mp3")
        let result = try AudioTrimService.trim(
            source: source, startSeconds: 1, endSeconds: 3, to: .newFile(destination))

        #expect(!result.replacedOriginal)
        #expect(result.outputURL == destination)
        #expect(try Data(contentsOf: source) == originalBytes)

        let trimmedDuration = try await duration(of: destination)
        #expect(abs(trimmedDuration - 2) < 0.15)
    }

    @Test func trimsInPlaceAndKeepsABackupOfTheOriginal() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source.mp3")
        guard try makeTestMP3(at: source, toneSeconds: 6) != nil else { return }

        let result = try AudioTrimService.trim(
            source: source, startSeconds: 0, endSeconds: 2, to: .inPlace)

        #expect(result.replacedOriginal)
        #expect(result.outputURL == source)

        let trimmedDuration = try await duration(of: source)
        #expect(abs(trimmedDuration - 2) < 0.15)

        let backupURL = try #require(result.originalBackupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backupDuration = try await duration(of: backupURL)
        #expect(abs(backupDuration - 6) < 0.15)
    }

    /// The whole reason in-place trimming is safe to offer: Serato's cue
    /// points and beatgrid are anchored to the old timeline, so they must not
    /// survive into the trimmed file.
    @Test func trimStripsSeratoAnalysisButKeepsTitleAndArtist() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source.mp3")
        guard let ffmpeg = AudioTrimService.ffmpegExecutablePath() else { return }
        guard try makeTestMP3(at: source, toneSeconds: 6) != nil else { return }

        // Re-mux with real text tags, then splice a Serato marker object in
        // front so the file looks like one Serato has analyzed.
        let tagged = scratch.appendingPathComponent("tagged.mp3")
        let tagProcess = Process()
        tagProcess.executableURL = URL(fileURLWithPath: ffmpeg)
        tagProcess.arguments = [
            "-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
            "-c", "copy", "-id3v2_version", "3",
            "-metadata", "title=Trim Me", "-metadata", "artist=Test Artist",
            tagged.path
        ]
        tagProcess.standardError = FileHandle.nullDevice
        try tagProcess.run()
        tagProcess.waitUntilExit()
        try #require(tagProcess.terminationStatus == 0)

        let trimmed = scratch.appendingPathComponent("trimmed.mp3")
        try AudioTrimService.trim(
            source: tagged, startSeconds: 1, endSeconds: 4, to: .newFile(trimmed))

        #expect(!SeratoAnalysisTagReader.summary(forFileAt: trimmed).hasAnyAnalysis)

        let metadata = try await AVURLAsset(url: trimmed).load(.commonMetadata)
        let title = try await metadata
            .first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
        #expect(title == "Trim Me")
    }
}

@Suite(.serialized)
struct AudioWaveformSamplerTests {

    @Test func resampleKeepsThePeakOfEachSourceWindow() {
        let peaks: [Float] = [0.1, 0.9, 0.2, 0.3, 0.8, 0.1]
        #expect(AudioWaveformSampler.resample(peaks, to: 3) == [0.9, 0.3, 0.8])
    }

    @Test func resampleUpsamplesWithoutLosingTheShape() {
        let peaks: [Float] = [0.2, 1.0]
        let upsampled = AudioWaveformSampler.resample(peaks, to: 4)
        #expect(upsampled.count == 4)
        #expect(upsampled.first == 0.2)
        #expect(upsampled.last == 1.0)
    }

    @Test func normalizeScalesTheLoudestPeakToOne() {
        #expect(AudioWaveformSampler.normalized([0.1, 0.25, 0.5]) == [0.2, 0.5, 1.0])
    }

    @Test func normalizeLeavesASilentEnvelopeAlone() {
        #expect(AudioWaveformSampler.normalized([0, 0, 0]) == [0, 0, 0])
    }

    /// Two seconds of silence, then eight of tone: the suggestion must land
    /// near 2s, not at 0.
    @Test func loudBoundsFindTheStartOfTheAudio() throws {
        let peaks: [Float] = Array(repeating: 0.0, count: 20) + Array(repeating: 0.8, count: 80)
        let waveform = AudioWaveform(peaks: peaks, duration: 10)

        let bounds = try #require(AudioWaveformSampler.loudBounds(in: waveform, paddingSeconds: 0))

        // 20 silent buckets of 0.1s each, minus the one-bucket outward pad.
        #expect(abs(bounds.start - 1.9) < 0.01)
        #expect(abs(bounds.end - 10.0) < 0.01)
    }

    @Test func loudBoundsClampToTheFileAndNeverGoNegative() throws {
        let waveform = AudioWaveform(peaks: Array(repeating: 0.9, count: 50), duration: 5)

        let bounds = try #require(AudioWaveformSampler.loudBounds(in: waveform, paddingSeconds: 1))

        #expect(bounds.start == 0)
        #expect(bounds.end == 5)
    }

    /// Trimming a wholly silent file to nothing is never what the user meant,
    /// so the detector declines rather than proposing an empty selection.
    @Test func loudBoundsReturnNilForASilentFile() {
        let waveform = AudioWaveform(peaks: Array(repeating: 0.0, count: 50), duration: 5)
        #expect(AudioWaveformSampler.loudBounds(in: waveform) == nil)
    }

    @Test func waveformOfARealFileHasTheRightDurationAndShape() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let ffmpeg = AudioTrimService.ffmpegExecutablePath() else { return }
        let source = scratch.appendingPathComponent("tone.mp3")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "aevalsrc=0:d=2[a];sine=frequency=440:duration=4[b];[a][b]concat=n=2:v=0:a=1",
            "-ar", "44100", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k",
            source.path
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }

        let waveform = try await AudioWaveformSampler.waveform(
            forFileAt: source, resolution: .totalBuckets(600))

        #expect(waveform.peaks.count == 600)
        #expect(abs(waveform.duration - 6) < 0.2)
        // Leading silence is quiet, the tone that follows is not.
        #expect((waveform.peaks.first ?? 1) < 0.05)
        #expect((waveform.peaks.last ?? 0) > 0.5)

        let bounds = try #require(AudioWaveformSampler.loudBounds(in: waveform, paddingSeconds: 0))
        #expect(abs(bounds.start - 2) < 0.25)
    }

    // MARK: - Resolution

    @Test func perSecondResolutionScalesWithTrackLength() {
        let resolution = AudioWaveformSampler.Resolution.perSecond(400)
        #expect(resolution.bucketCount(forDuration: 10) == 4_000)
        #expect(resolution.bucketCount(forDuration: 300) == 120_000)
    }

    /// A long DJ set must not allocate without bound just because it's long.
    @Test func perSecondResolutionIsCappedForVeryLongFiles() {
        let resolution = AudioWaveformSampler.Resolution.perSecond(400, maximumTotal: 10_000)
        #expect(resolution.bucketCount(forDuration: 3_600) == 10_000)
    }

    @Test func totalBucketsResolutionIgnoresDuration() {
        let resolution = AudioWaveformSampler.Resolution.totalBuckets(600)
        #expect(resolution.bucketCount(forDuration: 10) == 600)
        #expect(resolution.bucketCount(forDuration: 900) == 600)
    }

    // MARK: - Zoom windows

    /// Zooming has to read from the stored envelope, not stretch what's drawn:
    /// a window covering a tenth of the file must show that tenth's peaks.
    @Test func windowedPeaksReadFromTheRequestedSliceOnly() {
        // Loud only in the second quarter of the file.
        var peaks = [Float](repeating: 0.1, count: 100)
        for index in 25..<50 { peaks[index] = 1.0 }
        let waveform = AudioWaveform(peaks: peaks, duration: 10)

        let quiet = waveform.peaks(from: 0, to: 2.5, bucketCount: 20)
        let loud = waveform.peaks(from: 2.5, to: 5, bucketCount: 20)

        #expect(quiet.count == 20)
        #expect(loud.count == 20)
        #expect((quiet.max() ?? 1) < 0.5)
        #expect((loud.min() ?? 0) > 0.5)
    }

    @Test func windowedPeaksClampToTheFileBounds() {
        let waveform = AudioWaveform(peaks: Array(repeating: 0.5, count: 100), duration: 10)

        let overshoot = waveform.peaks(from: -5, to: 50, bucketCount: 30)

        #expect(overshoot.count == 30)
        #expect(overshoot.allSatisfy { $0 == 0.5 })
    }

    @Test func windowedPeaksReturnNothingForAnEmptyOrInvertedRange() {
        let waveform = AudioWaveform(peaks: Array(repeating: 0.5, count: 100), duration: 10)

        #expect(waveform.peaks(from: 5, to: 5, bucketCount: 20).isEmpty)
        #expect(waveform.peaks(from: 8, to: 2, bucketCount: 20).isEmpty)
    }

    /// Deep zoom asks for more columns than the slice has samples; it must
    /// still fill the width rather than returning a stub.
    @Test func windowedPeaksUpsampleWhenZoomedPastTheStoredResolution() {
        let waveform = AudioWaveform(peaks: Array(repeating: 0.7, count: 100), duration: 10)

        let deep = waveform.peaks(from: 5.0, to: 5.1, bucketCount: 400)

        #expect(deep.count == 400)
        #expect(deep.allSatisfy { $0 == 0.7 })
    }

    @Test func waveformOfAMissingFileThrowsAReadableError() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp3")

        await #expect(throws: AudioWaveformSampler.SamplingError.self) {
            _ = try await AudioWaveformSampler.waveform(forFileAt: missing)
        }
    }
}
