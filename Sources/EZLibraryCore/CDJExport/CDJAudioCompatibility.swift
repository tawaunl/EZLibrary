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

public struct CDJExportOptions: Sendable, Equatable {
    /// Convert anything older players might not play (FLAC, ALAC/AAC, hi-res or
    /// floating-point audio, unusual sample rates) to 16-bit 44.1 kHz stereo
    /// WAV/AIFF. Off copies every file exactly as it is, which suits newer players.
    public var maximumCompatibility = true

    /// Allow replacing a library on the stick that this app didn't write (for example
    /// one exported from rekordbox). Off by default, because its playlists would be lost.
    public var replaceForeignLibrary = false

    public init(maximumCompatibility: Bool = true, replaceForeignLibrary: Bool = false) {
        self.maximumCompatibility = maximumCompatibility
        self.replaceForeignLibrary = replaceForeignLibrary
    }
}

/// The format a track is converted to. Only PCM: macOS can't encode MP3, and
/// PCM is what every CDJ generation plays.
public enum CDJAudioConversion: String, Codable, Sendable, Equatable {
    case wav
    case aiff

    var pathExtension: String { rawValue == "aiff" ? "aiff" : "wav" }
    var fileType: CDJFileType { self == .wav ? .wav : .aiff }
    /// Recorded in the manifest so changing the recipe invalidates old copies.
    var profile: String { "pcm16-44100-stereo-\(rawValue)" }

    static let sampleRate = 44_100
    static let bitrateKbps = 1_411

    /// Bytes a converted file takes, close enough to plan space with.
    static func estimatedSize(durationSeconds: Double) -> Int {
        Int(durationSeconds * Double(sampleRate) * 4) + 4_096
    }

    /// WAV and AIFF both store sizes in 32 bits.
    static let maximumFileSize = Int(UInt32.max)
}

/// What a file looks like to a player, read from the file itself.
struct CDJAudioProbe: Sendable, Equatable {
    var sampleRate: Double
    var channels: Int
    var bitDepth: Int
    var isIntegerPCM: Bool
    var durationSeconds: Double

    static func read(_ url: URL) -> CDJAudioProbe? {
        // Open through a fresh URL so a cached stale state can't be read.
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: url.path)) else { return nil }
        let format = file.fileFormat
        let settings = format.settings
        let depth = (settings[AVLinearPCMBitDepthKey] as? Int) ?? 0
        let isFloat = (settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
        let isPCM = (settings[AVFormatIDKey] as? UInt32) == kAudioFormatLinearPCM
        let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
        return CDJAudioProbe(
            sampleRate: format.sampleRate, channels: Int(format.channelCount), bitDepth: depth,
            isIntegerPCM: isPCM && !isFloat, durationSeconds: duration)
    }
}

enum CDJAudioDecision: Equatable {
    case copy
    case convert(CDJAudioConversion)
    case refuse(String)
}

enum CDJAudioCompatibility {
    private static let playableRates: Set<Double> = [44_100, 48_000]

    /// What to do with a track of kind `type`. `probe` is nil when the file couldn't be read.
    static func decide(
        type: CDJFileType, probe: CDJAudioProbe?, fileSize: Int, options: CDJExportOptions
    ) -> CDJAudioDecision {
        if fileSize > Int(UInt32.max) {
            return .refuse("The file is larger than 4 GB, which a USB stick formatted for CDJs can't hold.")
        }
        if let probe, probe.channels > 2 {
            return .refuse("It has \(probe.channels) channels; CDJs play stereo.")
        }
        guard options.maximumCompatibility else { return .copy }

        let target: CDJAudioConversion = type == .aiff ? .aiff : .wav
        let converted: CDJAudioDecision
        if let probe, probe.durationSeconds > 0,
           CDJAudioConversion.estimatedSize(durationSeconds: probe.durationSeconds) > CDJAudioConversion.maximumFileSize {
            converted = .refuse("It is too long to convert to a WAV or AIFF file.")
        } else {
            converted = .convert(target)
        }

        switch type {
        case .mp3:
            // Without a probe we can't tell, and an MP3 is the safest thing to leave alone.
            guard let probe else { return .copy }
            return playableRates.contains(probe.sampleRate) ? .copy : converted
        case .wav, .aiff:
            guard let probe else { return .copy }
            let depthOK = probe.bitDepth == 16 || probe.bitDepth == 24
            return probe.isIntegerPCM && depthOK && playableRates.contains(probe.sampleRate) ? .copy : converted
        case .flac, .m4a:
            guard probe != nil else { return .refuse("The file couldn't be read, so it can't be converted.") }
            return converted
        }
    }
}
