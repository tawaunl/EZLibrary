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

/// One 1/150 s slice of a track: the loudest sample in each of three bands and
/// overall, each out of 255. Low is the kick, mid the body, high the hats.
/// Every waveform a CDJ draws is encoded from these.
public struct CDJBandColumn: Sendable, Equatable {
    public var low: UInt8
    public var mid: UInt8
    public var high: UInt8
    public var peak: UInt8

    public init(low: UInt8 = 0, mid: UInt8 = 0, high: UInt8 = 0, peak: UInt8 = 0) {
        self.low = low
        self.mid = mid
        self.high = high
        self.peak = peak
    }
}

/// Splits audio into low, mid and high bands with two one-pole filters
/// (crossovers at 200 Hz and 2 kHz) and keeps each band's peak per column.
/// Works on any number of buffers, so a long file is never held whole.
struct CDJBandAccumulator {
    static let columnsPerSecond = 150.0

    private let samplesPerColumn: Int
    private let lowCoefficient: Float
    private let highCoefficient: Float
    private var lowState: Float = 0
    private var highState: Float = 0
    private var filled = 0
    private var open: (low: Float, mid: Float, high: Float, peak: Float) = (0, 0, 0, 0)
    private(set) var columns: [CDJBandColumn] = []
    private(set) var sampleCount = 0
    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        samplesPerColumn = max(1, Int(sampleRate / Self.columnsPerSecond))
        func coefficient(_ cutoff: Double) -> Float {
            Float(min(max(exp(-2 * Double.pi * cutoff / max(sampleRate, 1)), 0), 0.9999))
        }
        lowCoefficient = coefficient(200)
        highCoefficient = coefficient(2_000)
    }

    mutating func push(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            lowState = sample * (1 - lowCoefficient) + lowState * lowCoefficient
            highState = sample * (1 - highCoefficient) + highState * highCoefficient
            let low = lowState
            let belowTwoK = highState
            open.low = max(open.low, abs(low))
            open.mid = max(open.mid, abs(belowTwoK - low))
            open.high = max(open.high, abs(sample - belowTwoK))
            open.peak = max(open.peak, abs(sample))
            filled += 1
            sampleCount += 1
            if filled == samplesPerColumn { closeColumn() }
        }
    }

    /// The columns, including a final partial one.
    mutating func finish() -> [CDJBandColumn] {
        if filled > 0 { closeColumn() }
        return columns
    }

    private mutating func closeColumn() {
        func byte(_ value: Float) -> UInt8 { UInt8(min(max(value, 0), 1) * 255) }
        columns.append(CDJBandColumn(
            low: byte(open.low), mid: byte(open.mid), high: byte(open.high), peak: byte(open.peak)))
        open = (0, 0, 0, 0)
        filled = 0
    }
}

enum CDJBandAnalyzer {
    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// Decodes the track and returns its columns and length. Throws if it can't be decoded.
    static func analyze(fileAt url: URL) throws -> (columns: [CDJBandColumn], durationSeconds: Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: url.path))
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CDJAudioConverter.ConversionError.cannotOpen(url.lastPathComponent)
        }
        var accumulator = CDJBandAccumulator(sampleRate: format.sampleRate)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))

        while file.framePosition < file.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[channel][frame] }
                mono[frame] = sum / Float(channels)
            }
            mono.withUnsafeBufferPointer { accumulator.push(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
        }
        let duration = Double(accumulator.sampleCount) / format.sampleRate
        return (accumulator.finish(), duration)
    }
}
