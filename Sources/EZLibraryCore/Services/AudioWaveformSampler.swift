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
import AVFoundation

/// A peak envelope for one audio file: `peaks[i]` is the loudest sample in the
/// slice of audio covering `[i, i+1) / peaks.count` of the duration.
public struct AudioWaveform: Sendable, Equatable {
    /// Normalised 0...1 peak amplitudes, oldest first.
    public let peaks: [Float]
    public let duration: TimeInterval

    public init(peaks: [Float], duration: TimeInterval) {
        self.peaks = peaks
        self.duration = duration
    }

    /// The playback time at the start of bucket `index`.
    public func time(forBucket index: Int) -> TimeInterval {
        guard !peaks.isEmpty else { return 0 }
        return duration * (Double(index) / Double(peaks.count))
    }

    /// The slice of the envelope covering `start...end`, resampled to
    /// `bucketCount` columns for display.
    ///
    /// This is what makes zooming worthwhile: the stored envelope is sampled
    /// far finer than any one screen needs, so zooming in reveals real detail
    /// instead of stretching the same columns wider.
    public func peaks(
        from start: TimeInterval,
        to end: TimeInterval,
        bucketCount: Int
    ) -> [Float] {
        guard !peaks.isEmpty, bucketCount > 0, duration > 0, end > start else { return [] }

        let clampedStart = max(0, min(start, duration))
        let clampedEnd = max(clampedStart, min(end, duration))

        let lower = Int((clampedStart / duration * Double(peaks.count)).rounded(.down))
        let upper = Int((clampedEnd / duration * Double(peaks.count)).rounded(.up))
        let range = max(0, lower)..<min(peaks.count, max(lower + 1, upper))
        guard !range.isEmpty else { return [] }

        return AudioWaveformSampler.resample(Array(peaks[range]), to: bucketCount)
    }
}

/// Decodes an audio file down to a peak envelope for waveform display and
/// silence detection.
///
/// Deliberately built on AVFoundation rather than ffmpeg: it runs in-process
/// with no external tool, so the editor can draw a waveform even on a machine
/// where the Homebrew tools aren't installed yet.
public enum AudioWaveformSampler {
    /// How finely to sample the file.
    public enum Resolution: Sendable, Equatable {
        /// A fixed number of buckets spread across the whole file.
        case totalBuckets(Int)
        /// A fixed time resolution, so a long track gets proportionally more
        /// detail. Use this when the envelope will be zoomed into; the cap
        /// keeps a DJ set-length file from allocating without bound.
        case perSecond(Double, maximumTotal: Int = 240_000)

        func bucketCount(forDuration duration: TimeInterval) -> Int {
            switch self {
            case let .totalBuckets(count):
                return max(1, count)
            case let .perSecond(rate, maximumTotal):
                return max(1, min(maximumTotal, Int((duration * rate).rounded())))
            }
        }
    }

    public enum SamplingError: Error, LocalizedError {
        case fileMissing(URL)
        case noAudioTrack(URL)
        case decodeFailed(URL, underlying: Error?)

        public var errorDescription: String? {
            switch self {
            case let .fileMissing(url):
                return "Couldn't find the audio file: \(url.lastPathComponent)."
            case let .noAudioTrack(url):
                return "\(url.lastPathComponent) has no audio track to display."
            case let .decodeFailed(url, underlying):
                let detail = underlying.map { " (\($0.localizedDescription))" } ?? ""
                return "Couldn't read the audio in \(url.lastPathComponent)\(detail)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .fileMissing:
                return "Reload the library, or use Missing Tracks to relocate the file."
            case .noAudioTrack:
                return "Check the file plays in Serato or Music before editing it."
            case .decodeFailed:
                return "The file may be corrupt or in a format macOS can't decode. Try playing it first."
            }
        }
    }

    /// Builds a peak envelope at the requested resolution.
    ///
    /// Decoding is streamed buffer by buffer, so memory stays flat regardless
    /// of track length. Runs off the main actor; a long track takes a moment.
    public static func waveform(
        forFileAt url: URL,
        resolution: Resolution = .totalBuckets(1200),
        fileManager: FileManager = .default
    ) async throws -> AudioWaveform {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SamplingError.fileMissing(url)
        }

        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let audioTrack: AVAssetTrack
        do {
            duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw SamplingError.noAudioTrack(url)
            }
            audioTrack = track
        } catch let error as SamplingError {
            throw error
        } catch {
            throw SamplingError.decodeFailed(url, underlying: error)
        }

        guard duration.isFinite, duration > 0 else {
            throw SamplingError.decodeFailed(url, underlying: nil)
        }
        let targetBuckets = resolution.bucketCount(forDuration: duration)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SamplingError.decodeFailed(url, underlying: error)
        }

        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw SamplingError.decodeFailed(url, underlying: nil)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SamplingError.decodeFailed(url, underlying: reader.error)
        }

        // Sized from the declared duration and stream format. Channels are
        // folded together rather than mixed down: for a peak envelope the
        // loudest sample in the window is what matters, not which channel it
        // came from.
        var samplesPerBucket = 0
        var peaks: [Float] = []
        peaks.reserveCapacity(targetBuckets + 1)
        var bucketPeak: Float = 0
        var samplesInBucket = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            if samplesPerBucket == 0 {
                samplesPerBucket = estimatedSamplesPerBucket(
                    sampleBuffer: sampleBuffer, duration: duration, bucketCount: targetBuckets)
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
                let dataPointer else {
                continue
            }

            let sampleCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                for index in 0..<sampleCount {
                    let magnitude = abs(samples[index])
                    if magnitude > bucketPeak { bucketPeak = magnitude }
                    samplesInBucket += 1

                    if samplesInBucket >= samplesPerBucket {
                        peaks.append(bucketPeak)
                        bucketPeak = 0
                        samplesInBucket = 0
                    }
                }
            }
        }

        if samplesInBucket > 0 {
            peaks.append(bucketPeak)
        }

        if reader.status == .failed {
            throw SamplingError.decodeFailed(url, underlying: reader.error)
        }
        guard !peaks.isEmpty else {
            throw SamplingError.decodeFailed(url, underlying: reader.error)
        }

        return AudioWaveform(
            peaks: normalized(resample(peaks, to: targetBuckets)),
            duration: duration
        )
    }

    /// The span of audio that isn't leading/trailing silence, as a start/end
    /// time pair — the "detect silence" suggestion in the trim editor.
    ///
    /// Returns nil when the whole file sits below the threshold, since trimming
    /// a silent file to nothing is never what the user meant.
    public static func loudBounds(
        in waveform: AudioWaveform,
        thresholdDecibels: Double = -45,
        paddingSeconds: TimeInterval = 0.1
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard !waveform.peaks.isEmpty, waveform.duration > 0 else { return nil }

        let threshold = Float(pow(10, thresholdDecibels / 20))
        guard let firstLoud = waveform.peaks.firstIndex(where: { $0 >= threshold }),
              let lastLoud = waveform.peaks.lastIndex(where: { $0 >= threshold }) else {
            return nil
        }

        // The first loud bucket starts somewhere inside its own window, so pad
        // outward by a bucket on each side before the user-facing padding.
        let bucketDuration = waveform.duration / Double(waveform.peaks.count)
        let start = max(0, waveform.time(forBucket: firstLoud) - bucketDuration - paddingSeconds)
        let end = min(waveform.duration, waveform.time(forBucket: lastLoud + 1) + bucketDuration + paddingSeconds)

        guard end > start else { return nil }
        return (start, end)
    }

    // MARK: - Helpers

    private static func estimatedSamplesPerBucket(
        sampleBuffer: CMSampleBuffer,
        duration: TimeInterval,
        bucketCount: Int
    ) -> Int {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 1
        }
        let sampleRate = streamDescription.pointee.mSampleRate
        let channels = Double(max(1, streamDescription.pointee.mChannelsPerFrame))
        let totalSamples = duration * sampleRate * channels
        return max(1, Int((totalSamples / Double(bucketCount)).rounded()))
    }

    /// Linearly resamples the collected peaks to exactly `target` buckets, so a
    /// wrong duration estimate can't change the shape of the returned envelope.
    /// Downsampling keeps the max of each source window rather than averaging,
    /// which would flatten transients.
    static func resample(_ peaks: [Float], to target: Int) -> [Float] {
        guard !peaks.isEmpty, target > 0, peaks.count != target else { return peaks }

        var result: [Float] = []
        result.reserveCapacity(target)
        for index in 0..<target {
            let lower = Int((Double(index) / Double(target) * Double(peaks.count)).rounded(.down))
            let upper = Int((Double(index + 1) / Double(target) * Double(peaks.count)).rounded(.down))
            let range = lower..<max(lower + 1, min(upper, peaks.count))
            result.append(peaks[range.clamped(to: 0..<peaks.count)].max() ?? 0)
        }
        return result
    }

    /// Scales the envelope so its loudest point is 1.0, which keeps quiet
    /// tracks legible in the editor. A silent file is returned untouched.
    static func normalized(_ peaks: [Float]) -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { $0 / loudest }
    }
}
