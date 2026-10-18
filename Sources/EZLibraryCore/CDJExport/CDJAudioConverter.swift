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

/// Converts a track to 16-bit 44.1 kHz stereo PCM in a WAV or AIFF container.
enum CDJAudioConverter {
    enum ConversionError: LocalizedError {
        case cannotOpen(String)
        case cannotConvert(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let name): return "Couldn't read \(name) to convert it."
            case .cannotConvert(let name): return "Couldn't convert \(name) for CDJs."
            }
        }
    }

    /// 320 kbps 44.1 kHz stereo MP3 through ffmpeg, keeping the tags and cover. A
    /// cover ffmpeg can't carry over isn't worth losing the track for, so that is retried without it.
    static func encodeMP3(from source: URL, to destination: URL, with ffmpeg: URL) throws {
        let name = source.lastPathComponent
        func arguments(withCover: Bool) -> [String] {
            ["-nostdin", "-y", "-v", "error", "-i", source.path, "-map", "0:a:0"]
                + (withCover ? ["-map", "0:v:0?", "-c:v", "copy"] : ["-vn"])
                + ["-c:a", "libmp3lame", "-b:a", "\(CDJAudioConversion.mp3BitrateKbps)k",
                   "-ar", "\(CDJAudioConversion.sampleRate)", "-ac", "2",
                   "-map_metadata", "0", "-id3v2_version", "3", "-f", "mp3", destination.path]
        }
        for withCover in [true, false] {
            try? FileManager.default.removeItem(at: destination)
            guard let result = try? ProcessRunner.run(
                executableURL: ffmpeg, arguments: arguments(withCover: withCover), standardOutput: .discard) else {
                throw ConversionError.cannotConvert(name)
            }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if result.didSucceed, size > 0 { return }
        }
        try? FileManager.default.removeItem(at: destination)
        throw ConversionError.cannotConvert(name)
    }

    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// Streams `source` through a converter into `destination`, so memory stays
    /// flat however long the track is. Mono is spread to both channels, and
    /// the sample rate is converted at the highest quality.
    static func convert(
        from source: URL, to destination: URL, as target: CDJAudioConversion, encoder: URL? = nil
    ) throws {
        let name = source.lastPathComponent
        if target == .mp3 {
            guard let encoder else { throw ConversionError.cannotConvert(name) }
            try encodeMP3(from: source, to: destination, with: encoder)
            return
        }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: URL(fileURLWithPath: source.path))
        } catch {
            throw ConversionError.cannotOpen(name)
        }

        let bigEndian = target == .aiff
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(CDJAudioConversion.sampleRate),
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(CDJAudioConversion.sampleRate),
            channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw ConversionError.cannotConvert(name)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        if input.processingFormat.channelCount == 1 {
            converter.channelMap = [0, 0]
        }

        try? FileManager.default.removeItem(at: destination)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw ConversionError.cannotConvert(name)
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else {
            throw ConversionError.cannotConvert(name)
        }
        let ratio = outputFormat.sampleRate / input.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 4_096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ConversionError.cannotConvert(name)
        }

        var reachedEnd = false
        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputBuffer.frameLength = 0
                do {
                    try input.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error { throw ConversionError.cannotConvert(name) }
            if outputBuffer.frameLength > 0 {
                do { try output.write(from: outputBuffer) } catch { throw ConversionError.cannotConvert(name) }
            }
            if status == .endOfStream { break }
        }
    }
}
