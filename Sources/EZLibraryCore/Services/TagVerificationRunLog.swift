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

/// A permanent, local record of one verification run: what was asked, what
/// every track came back with, what it cost, and what the user then applied.
///
/// It exists so the questions that decide how this feature should be tuned —
/// how often the pass without search is enough, whether the cache is holding,
/// which model and effort produce fixes the user actually keeps — can be
/// answered from real runs instead of guessed. The run itself lives only in
/// memory and is gone when the app quits; this is what is left afterwards.
///
/// One JSON Lines file per run, one record per line, each with a `type`:
/// `run` (settings), `track` (a verified track), `failure`, `aborted`,
/// `applied` (each successful apply), and `finished` (totals). Nothing is ever
/// uploaded. Writing is best-effort: a full disk or a permissions problem loses
/// the log, never the run.
public final class TagVerificationRunLog: @unchecked Sendable {
    public let runID: UUID
    public let fileURL: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let pricing: ModelPricing?
    private var totals = Totals()
    private var didFinish = false

    // MARK: - Where logs live

    public static let directoryName = "Verification Runs"

    /// `~/Library/Application Support/EZLibrary/Verification Runs`
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EZLibrary", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Starting

    /// Opens a new log and writes its `run` record, or returns nil when the
    /// file cannot be created.
    ///
    /// - Parameter cloudOptions: the cloud settings, for a cloud run only.
    ///   They price each track when the model's rates are known — Claude, the
    ///   three built-in OpenAI models, or a model on this Mac — and leave the
    ///   cost out otherwise rather than guess at another provider's bill.
    public static func start(
        engine: TagVerificationEngineKind,
        cloudOptions: AITagVerificationService.Options?,
        trackCount: Int,
        selectionCount: Int,
        appVersion: String? = nil,
        in directory: URL? = defaultDirectory(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TagVerificationRunLog? {
        guard let directory else { return nil }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let runID = UUID()
        let stamp = fileNameFormatter.string(from: now)
        let url = directory.appendingPathComponent("\(stamp) \(runID.uuidString.prefix(8)).jsonl")
        guard fileManager.createFile(atPath: url.path, contents: nil) else { return nil }

        let pricing = cloudOptions?.pricing
        let log = TagVerificationRunLog(runID: runID, fileURL: url, pricing: pricing)
        log.write(RunRecord(
            runID: runID,
            startedAt: now,
            appVersion: appVersion,
            engine: engine.rawValue,
            engineName: engine.displayName,
            provider: cloudOptions?.provider.rawValue,
            model: cloudOptions?.modelName,
            effort: cloudOptions?.effort,
            useWebSearch: cloudOptions?.useWebSearch,
            useFingerprint: cloudOptions?.useFingerprint,
            useOnlineCandidates: cloudOptions?.useOnlineCandidates,
            searchEscalationConfidence: cloudOptions == nil ? nil : AITagVerificationService.searchEscalationConfidence,
            trackCount: trackCount,
            selectionCount: selectionCount
        ))
        return log
    }

    private init(runID: UUID, fileURL: URL, pricing: ModelPricing?) {
        self.runID = runID
        self.fileURL = fileURL
        self.pricing = pricing
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Recording

    /// - Parameter preselected: the proposals the review pre-ticked, so the
    ///   log can later show where the user overrode the automatic choice.
    public func record(
        _ result: TrackTagVerification,
        preselected: Set<UUID>,
        now: Date = Date()
    ) {
        let cost = cost(of: result)
        lock.lock()
        totals.verified += 1
        totals.webSearches += result.webSearchCount
        if result.neededSearchPass { totals.searchPasses += 1 }
        if let usage = result.usage { totals.usage = totals.usage + usage }
        if let cost { totals.cost += cost }
        lock.unlock()

        write(TrackRecord(
            at: now,
            file: result.track.fileURL.lastPathComponent,
            path: result.track.fileURL.path,
            engine: result.engineName,
            identityConfidence: result.identityConfidence,
            identitySummary: result.identitySummary,
            neededSearchPass: result.neededSearchPass,
            webSearchCount: result.webSearchCount,
            sourceURLs: result.sourceURLs.map(\.absoluteString),
            usage: result.usage.map(UsageRecord.init),
            costUSD: cost,
            timings: result.timings.map { timings in
                TimingsRecord(
                    lookupSeconds: timings.lookupSeconds,
                    modelSeconds: timings.modelSeconds,
                    toolCalls: timings.toolCalls
                )
            },
            fields: result.fields.map { field in
                FieldRecord(
                    field: field.field.rawValue,
                    verdict: field.verdict.rawValue,
                    current: field.currentValue,
                    proposed: field.proposedValue,
                    confidence: field.confidence,
                    evidence: field.evidence,
                    sourceURL: field.sourceURL?.absoluteString,
                    isChange: field.isChange,
                    preselected: preselected.contains(field.id)
                )
            },
            artwork: result.artwork.map { artwork in
                ArtworkRecord(
                    source: artwork.sourceName,
                    url: artwork.url.absoluteString,
                    album: artwork.albumTitle,
                    fileIsMissingArtwork: artwork.fileIsMissingArtwork,
                    preselected: preselected.contains(artwork.id)
                )
            }
        ))
    }

    public func recordFailure(track: Track, message: String, now: Date = Date()) {
        lock.lock()
        totals.failed += 1
        lock.unlock()
        write(FailureRecord(at: now, file: track.fileURL.lastPathComponent, path: track.fileURL.path, message: message))
    }

    public func recordAborted(message: String, now: Date = Date()) {
        write(AbortedRecord(at: now, message: message))
    }

    public enum ApplyOutcome: String, Sendable {
        /// Written to the files.
        case applied
        /// Offered for confirmation and turned down.
        case declined
        /// Confirmed, but the write failed.
        case failed
    }

    /// One apply decision: for each track involved, the proposals the user
    /// kept and the ones they unticked. Proposals on tracks that never appear
    /// in an `applied` record were never applied at all.
    public func recordApplied(
        _ decisions: [AppliedTrack],
        outcome: ApplyOutcome = .applied,
        error: String? = nil,
        now: Date = Date()
    ) {
        guard !decisions.isEmpty else { return }
        write(AppliedRecord(at: now, outcome: outcome.rawValue, error: error, tracks: decisions))
    }

    /// Writes the closing totals. Safe to call more than once — only the first
    /// call writes — so both a natural finish and a stop can call it.
    public func finish(cancelled: Bool, now: Date = Date()) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let snapshot = totals
        lock.unlock()

        write(FinishedRecord(
            at: now,
            cancelled: cancelled,
            verified: snapshot.verified,
            failed: snapshot.failed,
            searchPasses: snapshot.searchPasses,
            webSearches: snapshot.webSearches,
            usage: UsageRecord(snapshot.usage),
            costUSD: pricing == nil ? nil : snapshot.cost
        ))
    }

    // MARK: - Applied decisions

    public struct AppliedTrack: Encodable, Sendable {
        public let file: String
        public let path: String
        public let kept: [Decision]
        public let unticked: [Decision]
        /// "applied", "failed", "unticked", or nil when none was offered.
        public let artwork: String?

        public struct Decision: Encodable, Sendable {
            public let field: String
            public let from: String
            public let to: String
            public let confidence: Double
        }

        public init(
            result: TrackTagVerification,
            selectedFieldIDs: Set<UUID>,
            artworkSelected: Bool,
            artworkFailed: Bool
        ) {
            file = result.track.fileURL.lastPathComponent
            path = result.track.fileURL.path
            var kept: [Decision] = []
            var unticked: [Decision] = []
            for change in result.proposedChanges {
                let decision = Decision(
                    field: change.field.rawValue,
                    from: change.currentValue,
                    to: change.proposedValue,
                    confidence: change.confidence
                )
                if selectedFieldIDs.contains(change.id) {
                    kept.append(decision)
                } else {
                    unticked.append(decision)
                }
            }
            self.kept = kept
            self.unticked = unticked
            if let offered = result.artwork, offered.fileIsMissingArtwork {
                artwork = artworkSelected ? (artworkFailed ? "failed" : "applied") : "unticked"
            } else {
                artwork = nil
            }
        }
    }

    // MARK: - Internals

    private func cost(of result: TrackTagVerification) -> Double? {
        guard let pricing, let usage = result.usage else { return nil }
        return usage.tokenCost(at: pricing)
            + Double(result.webSearchCount) * AITagVerificationService.costPerWebSearch
    }

    private func write<Record: Encodable>(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    private struct Totals {
        var verified = 0
        var failed = 0
        var searchPasses = 0
        var webSearches = 0
        var usage = TagVerificationUsage.zero
        var cost = 0.0
    }

    // MARK: - Records

    private struct RunRecord: Encodable {
        let type = "run"
        let runID: UUID
        let startedAt: Date
        let appVersion: String?
        let engine: String
        let engineName: String
        let provider: String?
        let model: String?
        let effort: String?
        let useWebSearch: Bool?
        let useFingerprint: Bool?
        let useOnlineCandidates: Bool?
        let searchEscalationConfidence: Double?
        let trackCount: Int
        let selectionCount: Int
    }

    private struct UsageRecord: Encodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int

        init(_ usage: TagVerificationUsage) {
            inputTokens = usage.inputTokens
            outputTokens = usage.outputTokens
            cacheWriteTokens = usage.cacheWriteTokens
            cacheReadTokens = usage.cacheReadTokens
        }
    }

    private struct TimingsRecord: Encodable {
        let lookupSeconds: Double
        let modelSeconds: Double
        let toolCalls: Int
    }

    private struct FieldRecord: Encodable {
        let field: String
        let verdict: String
        let current: String
        let proposed: String
        let confidence: Double
        let evidence: String
        let sourceURL: String?
        let isChange: Bool
        let preselected: Bool
    }

    private struct ArtworkRecord: Encodable {
        let source: String
        let url: String
        let album: String
        let fileIsMissingArtwork: Bool
        let preselected: Bool
    }

    private struct TrackRecord: Encodable {
        let type = "track"
        let at: Date
        let file: String
        let path: String
        let engine: String
        let identityConfidence: Double
        let identitySummary: String
        let neededSearchPass: Bool
        let webSearchCount: Int
        let sourceURLs: [String]
        let usage: UsageRecord?
        let costUSD: Double?
        let timings: TimingsRecord?
        let fields: [FieldRecord]
        let artwork: ArtworkRecord?
    }

    private struct FailureRecord: Encodable {
        let type = "failure"
        let at: Date
        let file: String
        let path: String
        let message: String
    }

    private struct AbortedRecord: Encodable {
        let type = "aborted"
        let at: Date
        let message: String
    }

    private struct AppliedRecord: Encodable {
        let type = "applied"
        let at: Date
        let outcome: String
        let error: String?
        let tracks: [AppliedTrack]
    }

    private struct FinishedRecord: Encodable {
        let type = "finished"
        let at: Date
        let cancelled: Bool
        let verified: Int
        let failed: Int
        let searchPasses: Int
        let webSearches: Int
        let usage: UsageRecord
        let costUSD: Double?
    }
}
