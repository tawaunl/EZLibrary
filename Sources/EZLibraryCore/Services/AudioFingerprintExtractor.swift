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

/// Extracts raw Chromaprint fingerprints via `fpcalc`, in parallel.
///
/// This is the expensive stage of fingerprint duplicate detection, so callers
/// should gate hard (metadata group, then duration) before calling it.
public enum AudioFingerprintExtractor {
    public enum ExtractionError: Error, LocalizedError, Sendable {
        case fpcalcNotInstalled
        case unreadableFile(URL)
        case decodeFailed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .fpcalcNotInstalled:
                return "The audio fingerprint scanner (fpcalc) is not installed."
            case let .unreadableFile(url):
                return "Could not read audio file for fingerprinting: \(url.lastPathComponent)"
            case let .decodeFailed(url, detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = trimmed.isEmpty ? "" : " (\(trimmed))"
                return "Could not fingerprint \(url.lastPathComponent)\(suffix)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .fpcalcNotInstalled:
                return "Install it with: brew install chromaprint"
            case .unreadableFile:
                return "Check that the file still exists and is readable, then rescan."
            case .decodeFailed:
                return "The file may be corrupt or in an unsupported format. It will be skipped."
            }
        }
    }

    /// Seconds of audio to fingerprint per file. Shorter is proportionally
    /// faster (measured: 120s ≈ 0.14s/file, 60s ≈ 0.09s/file) and still far
    /// more than the ~10s the matcher needs to separate same from different.
    public static let defaultAnalysisSeconds = 120

    /// Files handed to a single `fpcalc` process on the fast path. Batching
    /// amortizes process spawn cost (~30% faster in measurement).
    private static let batchSize = 16

    /// Extracts one fingerprint. Attribution is unambiguous because the process
    /// only ever sees a single file.
    public static func extract(
        fileURL: URL,
        analysisSeconds: Int = defaultAnalysisSeconds,
        fpcalcPath: String? = nil
    ) throws -> AudioFingerprint {
        guard let fpcalc = fpcalcPath ?? AudioFingerprintService.fpcalcExecutablePath() else {
            throw ExtractionError.fpcalcNotInstalled
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ExtractionError.unreadableFile(fileURL)
        }

        let result = try runFpcalc(fpcalc: fpcalc, analysisSeconds: analysisSeconds, files: [fileURL])
        guard let fingerprint = result.fingerprints.first else {
            throw ExtractionError.decodeFailed(fileURL, result.stderr)
        }
        return fingerprint
    }

    /// Fingerprints many files across `concurrency` parallel `fpcalc` processes.
    ///
    /// Files that fail to decode are reported in `failures` and simply omitted
    /// from `fingerprints`; one bad file never fails the whole scan.
    ///
    /// `progress` is called with the number of files completed so far. It may
    /// be invoked from any thread.
    public static func extractMany(
        fileURLs: [URL],
        analysisSeconds: Int = defaultAnalysisSeconds,
        concurrency: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (fingerprints: [URL: AudioFingerprint], failures: [URL: ExtractionError]) {
        guard !fileURLs.isEmpty else { return ([:], [:]) }
        guard let fpcalc = AudioFingerprintService.fpcalcExecutablePath() else {
            throw ExtractionError.fpcalcNotInstalled
        }

        let chunks = stride(from: 0, to: fileURLs.count, by: batchSize).map {
            Array(fileURLs[$0..<min($0 + batchSize, fileURLs.count)])
        }

        let total = fileURLs.count
        let workerCount = max(1, min(concurrency, chunks.count))
        let counter = CompletionCounter()
        var fingerprints: [URL: AudioFingerprint] = [:]
        var failures: [URL: ExtractionError] = [:]

        // Chunks are striped across a fixed set of workers rather than
        // scheduled dynamically: files cost roughly the same to decode, so
        // static striping balances well without the bookkeeping.
        await withTaskGroup(
            of: (fingerprints: [URL: AudioFingerprint], failures: [URL: ExtractionError]).self
        ) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var localFingerprints: [URL: AudioFingerprint] = [:]
                    var localFailures: [URL: ExtractionError] = [:]

                    var index = worker
                    while index < chunks.count {
                        if Task.isCancelled { break }
                        let chunk = chunks[index]
                        let outcome = extractChunk(
                            chunk,
                            fpcalc: fpcalc,
                            analysisSeconds: analysisSeconds
                        )
                        localFingerprints.merge(outcome.fingerprints) { current, _ in current }
                        localFailures.merge(outcome.failures) { current, _ in current }

                        if let progress {
                            let done = await counter.add(chunk.count)
                            progress(done, total)
                        }
                        index += workerCount
                    }

                    return (localFingerprints, localFailures)
                }
            }

            for await outcome in group {
                fingerprints.merge(outcome.fingerprints) { current, _ in current }
                failures.merge(outcome.failures) { current, _ in current }
            }
        }

        try Task.checkCancellation()
        return (fingerprints, failures)
    }

    /// Fingerprints one chunk, preferring a single batched `fpcalc` call.
    ///
    /// `fpcalc` accepts many files but emits only bare DURATION/FINGERPRINT
    /// records with no filename, and it *aborts the remaining files* as soon as
    /// one fails to decode. Attributing records positionally is therefore only
    /// safe when the record count matches the input count exactly — otherwise a
    /// single corrupt file would shift every later fingerprint onto the wrong
    /// track, and this feature deletes files. So a short count falls back to
    /// one process per file, where attribution cannot be ambiguous.
    private static func extractChunk(
        _ chunk: [URL],
        fpcalc: String,
        analysisSeconds: Int
    ) -> (fingerprints: [URL: AudioFingerprint], failures: [URL: ExtractionError]) {
        if chunk.count > 1,
           let batched = try? runFpcalc(fpcalc: fpcalc, analysisSeconds: analysisSeconds, files: chunk),
           batched.fingerprints.count == chunk.count {
            var mapped: [URL: AudioFingerprint] = [:]
            for (url, fingerprint) in zip(chunk, batched.fingerprints) {
                mapped[url] = fingerprint
            }
            return (mapped, [:])
        }

        var fingerprints: [URL: AudioFingerprint] = [:]
        var failures: [URL: ExtractionError] = [:]
        for url in chunk {
            do {
                fingerprints[url] = try extract(
                    fileURL: url,
                    analysisSeconds: analysisSeconds,
                    fpcalcPath: fpcalc
                )
            } catch let error as ExtractionError {
                failures[url] = error
            } catch {
                failures[url] = .decodeFailed(url, error.localizedDescription)
            }
        }
        return (fingerprints, failures)
    }

    private static func runFpcalc(
        fpcalc: String,
        analysisSeconds: Int,
        files: [URL]
    ) throws -> (fingerprints: [AudioFingerprint], stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fpcalc)
        process.arguments = ["-raw", "-length", String(analysisSeconds)] + files.map(\.path)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ExtractionError.fpcalcNotInstalled
        }

        // Drain before waiting: a full pipe buffer would deadlock the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let errorText = String(data: errData, encoding: .utf8) ?? ""
        let output = String(data: outData, encoding: .utf8) ?? ""
        return (parse(output), errorText)
    }

    /// Parses `fpcalc -raw` output into fingerprints, in emission order.
    static func parse(_ output: String) -> [AudioFingerprint] {
        var fingerprints: [AudioFingerprint] = []
        var pendingDuration: Int?

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DURATION=") {
                pendingDuration = Int(line.dropFirst("DURATION=".count).prefix(while: \.isNumber))
            } else if line.hasPrefix("FINGERPRINT=") {
                let body = line.dropFirst("FINGERPRINT=".count)
                let hashes = body.split(separator: ",").compactMap { UInt32($0) }
                // A record needs both halves; a duration with no fingerprint is
                // not usable, and vice versa.
                if let duration = pendingDuration, !hashes.isEmpty {
                    fingerprints.append(AudioFingerprint(duration: duration, hashes: hashes))
                }
                pendingDuration = nil
            }
        }

        return fingerprints
    }
}

/// Serializes progress counting across the parallel extraction tasks.
private actor CompletionCounter {
    private var value = 0

    func add(_ delta: Int) -> Int {
        value += delta
        return value
    }
}
