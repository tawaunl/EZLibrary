// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import EZLibraryCore

/// Owns a verification run and everything it produces.
///
/// This lives outside the review sheet on purpose. A run can take minutes — the
/// on-device model is seconds per track, and a library-sized consensus pass is
/// several minutes — and holding that state in the sheet meant closing the
/// window threw the work away. With the state out here the sheet is just a view
/// of it: close it, carry on tagging or building crates, and reopen to find the
/// run where you left it, or already finished.
@MainActor
final class TagVerificationRunModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [TrackTagVerification] = []
    @Published private(set) var failures: [(track: Track, message: String)] = []
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    /// How many tracks were checked, as distinct from how many are still
    /// listed: applied tracks are removed from `results`, so its count stops
    /// being a record of the work done the moment anything is written.
    @Published private(set) var checkedCount = 0
    @Published private(set) var appliedCount = 0
    @Published private(set) var abortMessage: String?
    @Published private(set) var engineName = ""
    /// The track selection these results describe.
    ///
    /// The model outlives the sheet on purpose, which means it also outlives
    /// the selection that produced it. Without remembering what it ran on, a
    /// finished run kept being shown for a completely different set of tracks
    /// — the sheet stayed on its results screen with no way back to the start.
    @Published private(set) var selectionIDs: Set<UUID> = []

    /// Tokens and searches actually billed so far.
    ///
    /// Reported rather than estimated: every reply carries its own usage, so
    /// once a run is under way there is no need to guess what it is costing.
    @Published private(set) var usage = TagVerificationUsage.zero
    @Published private(set) var webSearches = 0
    /// Cloud tracks the pass without search did not settle. Against
    /// `checkedCount`, this is how often the cheap pass is enough.
    @Published private(set) var searchPassCount = 0
    /// Summed timings of the tracks that reported them, for the averages.
    @Published private(set) var timedTracks = 0
    @Published private(set) var lookupSeconds = 0.0
    @Published private(set) var modelSeconds = 0.0
    @Published private(set) var toolCalls = 0
    private var searchPassPossible = false
    private var pricing: ModelPricing?

    /// Which proposals are ticked. Held here rather than in the sheet so a
    /// review survives the window being closed and reopened.
    @Published var selectedFieldIDs: Set<UUID> = []
    @Published var selectedArtworkIDs: Set<UUID> = []

    private var task: Task<Void, Never>?
    /// Identifies the run `task` belongs to. A cancelled task does not stop on
    /// the spot — it finishes a moment later, on the main actor — so without
    /// this its closing writes land on whatever run is current by then: a run
    /// started in the meantime showed as finished with its task dropped (so
    /// Stop no longer reached it), and a reset showed "finished" instead of
    /// setup. A task only touches shared state while its ID is still this one.
    private var currentRunID: UUID?
    /// The permanent record of the current run. See `TagVerificationRunLog`.
    private var log: TagVerificationRunLog?

    /// Where this run is being recorded, for "Show Run Log".
    var logFileURL: URL? { log?.fileURL }

    var isRunning: Bool { phase == .running }

    /// True once there is something worth reopening the sheet for.
    var hasReviewableResults: Bool {
        results.contains { !$0.proposedChanges.isEmpty || $0.artwork?.fileIsMissingArtwork == true }
    }

    var outstandingChangeCount: Int {
        results.reduce(0) { $0 + $1.proposedChanges.count }
    }

    var selectedCount: Int {
        selectedFieldIDs.count + selectedArtworkIDs.count
    }

    // MARK: - Running

    /// - Parameter selection: everything the sheet was opened with, which may be
    ///   wider than `tracks` when the run is narrowed to the flagged ones. It
    ///   is what the results are matched against later.
    func start(
        tracks: [Track],
        selection: [Track],
        engine: TagVerificationEngineKind,
        consensusOptions: TagConsensusService.Options,
        cloudOptions: AITagVerificationService.Options
    ) {
        cancel()

        selectionIDs = Set(selection.map(\.id))

        usage = .zero
        webSearches = 0
        searchPassCount = 0
        timedTracks = 0
        lookupSeconds = 0
        modelSeconds = 0
        toolCalls = 0
        // Only the cloud tier bills; the other two are free, and showing them a
        // running total of $0.00 would just be noise. A cloud model is priced
        // only when its rates are known; another provider's bill is its own.
        pricing = engine == .cloudModel ? cloudOptions.pricing.flatMap { $0.isFree ? nil : $0 } : nil
        searchPassPossible = engine == .cloudModel
            && cloudOptions.useWebSearch
            && cloudOptions.provider.supportsWebSearch

        results = []
        failures = []
        selectedFieldIDs = []
        selectedArtworkIDs = []
        completedCount = 0
        checkedCount = 0
        appliedCount = 0
        totalCount = tracks.count
        abortMessage = nil
        engineName = engine.displayName
        phase = .running

        log = TagVerificationRunLog.start(
            engine: engine,
            cloudOptions: engine == .cloudModel ? cloudOptions : nil,
            trackCount: tracks.count,
            selectionCount: selection.count,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let threshold = TagVerificationCoordinator.confidenceThreshold(for: engine)
        // Captured, not read through `self`, so a run replaced by a newer one
        // still closes its own log rather than the new run's.
        let runLog = log
        let runID = UUID()
        currentRunID = runID
        task = Task { [weak self] in
            let events = TagVerificationCoordinator.verify(
                tracks: tracks,
                using: engine,
                consensusOptions: consensusOptions,
                cloudOptions: cloudOptions
            )
            for await event in events {
                guard let self, !Task.isCancelled, self.currentRunID == runID else { break }
                self.handle(event, minimumConfidence: threshold)
            }
            runLog?.finish(cancelled: Task.isCancelled)
            guard let self, self.currentRunID == runID else { return }
            self.phase = .finished
            self.task = nil
            self.currentRunID = nil
        }
    }

    /// Stops the run but keeps whatever it already found — a partial result is
    /// still worth reviewing.
    func cancel() {
        task?.cancel()
        task = nil
        // Whatever the stopped task does on its way out is now stale.
        currentRunID = nil
        if phase == .running {
            log?.finish(cancelled: true)
            phase = .finished
        }
    }

    /// Whether the current results belong to `selection`.
    ///
    /// An empty run matches nothing, so a fresh model always starts at setup.
    func matches(selection: [Track]) -> Bool {
        !selectionIDs.isEmpty && selectionIDs == Set(selection.map(\.id))
    }

    /// Clears everything, for when a new selection makes the old run irrelevant.
    func reset() {
        cancel()
        results = []
        failures = []
        selectedFieldIDs = []
        selectedArtworkIDs = []
        completedCount = 0
        totalCount = 0
        checkedCount = 0
        appliedCount = 0
        abortMessage = nil
        selectionIDs = []
        usage = .zero
        webSearches = 0
        searchPassCount = 0
        timedTracks = 0
        lookupSeconds = 0
        modelSeconds = 0
        toolCalls = 0
        searchPassPossible = false
        pricing = nil
        log = nil
        phase = .idle
    }

    private func handle(_ event: TagVerificationEvent, minimumConfidence: Double) {
        switch event {
        case let .started(total):
            totalCount = total
        case let .verified(result):
            completedCount += 1
            checkedCount += 1
            if let resultUsage = result.usage {
                usage += resultUsage
            }
            if result.neededSearchPass {
                searchPassCount += 1
            }
            if let timings = result.timings {
                timedTracks += 1
                lookupSeconds += timings.lookupSeconds
                modelSeconds += timings.modelSeconds
                toolCalls += timings.toolCalls
            }
            webSearches += result.webSearchCount
            results.append(result)
            preselect(result, minimumConfidence: minimumConfidence)
            let offered = Set(result.fields.map(\.id) + [result.artwork?.id].compactMap { $0 })
            log?.record(result, preselected: offered.intersection(selectedFieldIDs.union(selectedArtworkIDs)))
        case let .failed(track, message):
            completedCount += 1
            failures.append((track, message))
            log?.recordFailure(track: track, message: message)
        case let .aborted(message):
            abortMessage = message
            log?.recordAborted(message: message)
        case .finished:
            break
        }
    }

    /// Pre-ticks the proposals that are safe to trust and leaves the rest to be
    /// opted into. A confident verdict about the wrong recording is still
    /// wrong, so the identity confidence gates this as well.
    private func preselect(_ result: TrackTagVerification, minimumConfidence: Double) {
        guard result.identityConfidence >= TagVerificationCoordinator.identityConfidenceFloor else { return }
        for change in result.proposedChanges where change.confidence >= minimumConfidence {
            selectedFieldIDs.insert(change.id)
        }
        if let artwork = result.artwork, artwork.fileIsMissingArtwork {
            selectedArtworkIDs.insert(artwork.id)
        }
    }

    /// What the run has actually cost so far, or nil when the tier is free.
    ///
    /// Anthropic bills web searches separately from tokens, at a published
    /// $10 per 1,000, so both halves are counted.
    var spendSoFar: Double? {
        guard let pricing, checkedCount > 0 else { return nil }
        return usage.tokenCost(at: pricing) + Double(webSearches) * AITagVerificationService.costPerWebSearch
    }

    var spendSummary: String? {
        guard let spend = spendSoFar else { return nil }
        let perTrack = spend / Double(max(checkedCount, 1))
        let total = spend < 0.01 ? "<$0.01" : String(format: "$%.2f", spend)
        let each = String(format: "$%.3f", perTrack)
        var parts = ["\(total) so far — \(each) a track"]
        // Both of these are here to be checked against reality: how often the
        // pass without search is enough decides what this tier really costs,
        // and a cache share near zero means the cached prefix is breaking.
        if searchPassPossible {
            let settled = checkedCount - searchPassCount
            parts.append("\(settled) of \(checkedCount) settled without searching")
        }
        parts.append("\(webSearches) web search\(webSearches == 1 ? "" : "es")")
        if let share = cacheReadShare {
            parts.append("\(Int((share * 100).rounded()))% of input from cache")
        }
        return parts.joined(separator: ", ")
    }

    /// Average time a track takes, split into lookup and model, or nil when
    /// no track has reported timings. Shown for every engine — on the free
    /// ones speed is the only cost there is.
    var timingSummary: String? {
        guard timedTracks > 0 else { return nil }
        let count = Double(timedTracks)
        var text = String(
            format: "%.1f s a track on average — %.1f s looking up, %.1f s in the model",
            (lookupSeconds + modelSeconds) / count,
            lookupSeconds / count,
            modelSeconds / count
        )
        if toolCalls > 0 {
            text += ", \(toolCalls) extra search\(toolCalls == 1 ? "" : "es") by the model"
        }
        return text
    }

    /// Share of all input tokens served from the prompt cache, or nil before
    /// any input has been billed.
    var cacheReadShare: Double? {
        let total = usage.inputTokens + usage.cacheWriteTokens + usage.cacheReadTokens
        guard total > 0 else { return nil }
        return Double(usage.cacheReadTokens) / Double(total)
    }

    // MARK: - Applying

    struct ApplyOutcome {
        var updates: [(Track, SeratoTrackMetadataUpdate)] = []
        var artworkApplied = 0
        var artworkFailures: [String] = []
    }

    /// Builds the updates for everything currently ticked, downloading any
    /// selected artwork on the way.
    ///
    /// Artwork is fetched here rather than when the proposal appears, because
    /// pulling an image for every result would download art the user never
    /// asked to apply.
    func buildUpdates() async -> ApplyOutcome {
        var outcome = ApplyOutcome()

        for result in results {
            let fields = Set(
                result.proposedChanges
                    .filter { selectedFieldIDs.contains($0.id) }
                    .map(\.field)
            )
            let artwork = result.artwork
            let wantsArtwork = artwork.map { selectedArtworkIDs.contains($0.id) } ?? false
            guard !fields.isEmpty || wantsArtwork else { continue }

            var update = result.metadataUpdate(applying: fields)

            if wantsArtwork, let artwork {
                do {
                    update.artwork = try await ArtworkFetchService.fetchArtwork(from: artwork.url)
                    outcome.artworkApplied += 1
                } catch {
                    outcome.artworkFailures.append(result.track.fileURL.lastPathComponent)
                    // The tag changes are still worth writing without it.
                    if fields.isEmpty { continue }
                }
            }

            outcome.updates.append((result.track, update))
        }

        return outcome
    }

    /// Drops the tracks that were just written. Leaving them on screen showing
    /// their old values invites applying them twice.
    ///
    /// Called only after a successful write, so it is also where the log learns
    /// what the user kept and what they unticked.
    func forget(tracks written: [Track], artworkFailures: [String] = []) {
        let ids = Set(written.map(\.id))
        let failedArtwork = Set(artworkFailures)
        log?.recordApplied(results.filter { ids.contains($0.track.id) }.map { result in
            TagVerificationRunLog.AppliedTrack(
                result: result,
                selectedFieldIDs: selectedFieldIDs,
                artworkSelected: result.artwork.map { selectedArtworkIDs.contains($0.id) } ?? false,
                artworkFailed: failedArtwork.contains(result.track.fileURL.lastPathComponent)
            )
        })
        results.removeAll { ids.contains($0.track.id) }
        appliedCount += written.count
        selectedFieldIDs = []
        selectedArtworkIDs = []
    }
}
