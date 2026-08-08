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

/// Cuts an audio file down to a start/end range.
///
/// The cut is a stream copy — the encoded audio packets between the two points
/// are muxed into a new file untouched, so nothing is re-encoded and a 320kbps
/// MP3 stays a 320kbps MP3. Cut points land on the nearest packet boundary
/// (~26ms for MP3), which is well inside what a DJ trim needs.
///
/// Text tags and embedded cover art survive the copy. Serato's `GEOB` analysis
/// objects (cue points, loops, beatgrid, waveform overview) do not: ffmpeg
/// drops them, which is exactly what we want, since every one of them is
/// anchored to a timeline the trim has just shifted. See
/// `SeratoAnalysisTagReader` for the warning shown before this runs.
public enum AudioTrimService {
    /// Where the trimmed audio should land.
    public enum Destination: Sendable, Equatable {
        /// Overwrite the source file, keeping a timestamped backup of the
        /// original in the app's pre-write backup folder.
        case inPlace
        /// Write a new file, leaving the source untouched.
        case newFile(URL)
    }

    public struct TrimResult: Sendable {
        public let outputURL: URL
        /// True when the source file was overwritten.
        public let replacedOriginal: Bool
        /// Backup copy of the original, for in-place edits only.
        public let originalBackupURL: URL?
        public let trimmedDuration: TimeInterval

        public init(
            outputURL: URL,
            replacedOriginal: Bool,
            originalBackupURL: URL?,
            trimmedDuration: TimeInterval
        ) {
            self.outputURL = outputURL
            self.replacedOriginal = replacedOriginal
            self.originalBackupURL = originalBackupURL
            self.trimmedDuration = trimmedDuration
        }
    }

    public enum TrimError: Error, LocalizedError {
        case ffmpegNotFound
        case sourceMissing(URL)
        case invalidRange(start: TimeInterval, end: TimeInterval)
        case destinationExists(URL)
        case destinationFolderMissing(URL)
        case trimFailed(String)
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg isn't installed, so audio can't be trimmed."
            case let .sourceMissing(url):
                return "Couldn't find the audio file to trim: \(url.lastPathComponent)."
            case let .invalidRange(start, end):
                return "The trim range is invalid: the end point (\(format(end))) "
                    + "must come after the start point (\(format(start)))."
            case let .destinationExists(url):
                return "A file named \(url.lastPathComponent) already exists in that folder."
            case let .destinationFolderMissing(url):
                return "The destination folder doesn't exist: \(url.path)."
            case let .trimFailed(message):
                return "ffmpeg couldn't trim the file: \(message)"
            case .emptyOutput:
                return "The trim produced an empty file, so the original was left alone."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .ffmpegNotFound:
                return "Install the required tools from the banner at the top of the window, then retry."
            case .sourceMissing:
                return "Reload the library, or use Missing Tracks to relocate the file."
            case .invalidRange:
                return "Drag the trim handles so the selection covers at least a fraction of a second."
            case .destinationExists:
                return "Pick a different name, or choose Save In Place to overwrite the original."
            case .destinationFolderMissing:
                return "Choose a folder that exists, then retry."
            case .trimFailed, .emptyOutput:
                return "Check the file plays normally. If it does, report the message above as a bug."
            }
        }

        private func format(_ seconds: TimeInterval) -> String {
            String(format: "%.2fs", seconds)
        }
    }

    /// Shortest trim we accept. Below this the packet-boundary rounding of a
    /// stream copy can produce a file with no audio at all.
    public static let minimumDuration: TimeInterval = 0.1

    /// Resolves ffmpeg through the same lookup the rest of the app uses, so a
    /// Homebrew install picked up by the YouTube importer works here too.
    public static func ffmpegExecutablePath() -> String? {
        YouTubeAudioImportService.dependencyStatus().ffmpegPath
    }

    /// Proposes a non-colliding "… (Edit).mp3" sibling of `source`, adding a
    /// counter if that name is taken.
    public static func suggestedEditURL(
        for source: URL,
        suffix: String = " (Edit)",
        fileManager: FileManager = .default
    ) -> URL {
        let directory = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent

        for attempt in 1...500 {
            let candidateStem = attempt == 1 ? "\(stem)\(suffix)" : "\(stem)\(suffix) \(attempt)"
            var candidate = directory.appendingPathComponent(candidateStem)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        var fallback = directory.appendingPathComponent("\(stem)\(suffix) \(UUID().uuidString)")
        if !ext.isEmpty { fallback.appendPathExtension(ext) }
        return fallback
    }

    /// Trims `source` to `start...end` and writes the result to `destination`.
    ///
    /// Blocking (it waits on ffmpeg) — call it off the main actor. The source
    /// file is never modified until ffmpeg has produced a non-empty output, so
    /// a failure mid-run leaves the original intact.
    @discardableResult
    public static func trim(
        source: URL,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        to destination: Destination,
        fileManager: FileManager = .default
    ) throws -> TrimResult {
        guard let ffmpegPath = ffmpegExecutablePath() else {
            throw TrimError.ffmpegNotFound
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw TrimError.sourceMissing(source)
        }

        let start = max(0, startSeconds)
        guard endSeconds - start >= minimumDuration else {
            throw TrimError.invalidRange(start: startSeconds, end: endSeconds)
        }
        let duration = endSeconds - start

        let outputURL: URL
        switch destination {
        case .inPlace:
            outputURL = source
        case let .newFile(url):
            let folder = url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw TrimError.destinationFolderMissing(folder)
            }
            guard !fileManager.fileExists(atPath: url.path) else {
                throw TrimError.destinationExists(url)
            }
            outputURL = url
        }

        // ffmpeg won't mux in place, and we want a verified file before
        // touching anything the user owns, so it always writes to a sibling
        // temp file first. Same extension so ffmpeg picks the right muxer.
        let workingURL = temporaryURL(besides: outputURL, matchingExtensionOf: source)
        defer { try? fileManager.removeItem(at: workingURL) }

        try runFFmpeg(
            executablePath: ffmpegPath,
            source: source,
            start: start,
            duration: duration,
            output: workingURL
        )

        let outputSize = (try? fileManager.attributesOfItem(atPath: workingURL.path)[.size] as? Int) ?? nil
        guard let outputSize, outputSize > 0 else {
            throw TrimError.emptyOutput
        }

        switch destination {
        case .inPlace:
            // Snapshot first: once the swap lands, the pre-trim audio only
            // exists in the backup folder.
            let backupURL = try SeratoBackupBeforeWrite.snapshot(of: source)
            do {
                _ = try fileManager.replaceItemAt(source, withItemAt: workingURL)
            } catch {
                throw TrimError.trimFailed(error.localizedDescription)
            }
            return TrimResult(
                outputURL: source,
                replacedOriginal: true,
                originalBackupURL: backupURL,
                trimmedDuration: duration
            )

        case let .newFile(url):
            do {
                try fileManager.moveItem(at: workingURL, to: url)
            } catch {
                throw TrimError.trimFailed(error.localizedDescription)
            }
            return TrimResult(
                outputURL: url,
                replacedOriginal: false,
                originalBackupURL: nil,
                trimmedDuration: duration
            )
        }
    }

    // MARK: - ffmpeg

    private static func runFFmpeg(
        executablePath: String,
        source: URL,
        start: TimeInterval,
        duration: TimeInterval,
        output: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        // `-ss`/`-t` sit *before* `-i` on purpose. As input options they make
        // ffmpeg seek the demuxer, which re-reads the header and so carries the
        // attached cover-art frame into the output. As output options they run
        // after the picture frame at timestamp 0 has already been discarded,
        // silently dropping the artwork.
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-ss", String(format: "%.4f", start),
            "-t", String(format: "%.4f", duration),
            "-i", source.path,
            "-map", "0",
            "-map_metadata", "0",
            "-c", "copy",
            output.path
        ]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TrimError.ffmpegNotFound
        }

        // Drained before waiting: ffmpeg blocks once the pipe buffer fills, and
        // a noisy file would otherwise deadlock the wait below.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TrimError.trimFailed(message.isEmpty ? "exit code \(process.terminationStatus)" : message)
        }
    }

    private static func temporaryURL(besides destination: URL, matchingExtensionOf source: URL) -> URL {
        let directory = destination.deletingLastPathComponent()
        var url = directory.appendingPathComponent(".ezlibrary-trim-\(UUID().uuidString)")
        let ext = source.pathExtension
        if !ext.isEmpty { url.appendPathExtension(ext) }
        return url
    }
}
