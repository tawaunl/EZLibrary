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

    /// Tokens and searches actually billed so far.
    ///
    /// Reported rather than estimated: every reply carries its own usage, so
    /// once a run is under way there is no need to guess what it is costing.
    @Published private(set) var inputTokens = 0
    @Published private(set) var outputTokens = 0
    @Published private(set) var webSearches = 0
    private var pricing: ClaudeModel?

    /// Which proposals are ticked. Held here rather than in the sheet so a
    /// review survives the window being closed and reopened.
    @Published var selectedFieldIDs: Set<UUID> = []
    @Published var selectedArtworkIDs: Set<UUID> = []

    private var task: Task<Void, Never>?

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

    func start(
        tracks: [Track],
        engine: TagVerificationEngineKind,
        consensusOptions: TagConsensusService.Options,
        cloudOptions: AITagVerificationService.Options
    ) {
        cancel()

        inputTokens = 0
        outputTokens = 0
        webSearches = 0
        // Only the cloud tier bills; the other two are free, and showing them a
        // running total of $0.00 would just be noise.
        pricing = engine == .cloudModel ? cloudOptions.model : nil

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

        let threshold = TagVerificationCoordinator.confidenceThreshold(for: engine)
        task = Task { [weak self] in
            let events = TagVerificationCoordinator.verify(
                tracks: tracks,
                using: engine,
                consensusOptions: consensusOptions,
                cloudOptions: cloudOptions
            )
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                self.handle(event, minimumConfidence: threshold)
            }
            self?.phase = .finished
            self?.task = nil
        }
    }

    /// Stops the run but keeps whatever it already found — a partial result is
    /// still worth reviewing.
    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running {
            phase = .finished
        }
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
        phase = .idle
    }

    private func handle(_ event: TagVerificationEvent, minimumConfidence: Double) {
        switch event {
        case let .started(total):
            totalCount = total
        case let .verified(result):
            completedCount += 1
            checkedCount += 1
            if let usage = result.usage {
                inputTokens += usage.inputTokens
                outputTokens += usage.outputTokens
            }
            webSearches += result.webSearchCount
            results.append(result)
            preselect(result, minimumConfidence: minimumConfidence)
        case let .failed(track, message):
            completedCount += 1
            failures.append((track, message))
        case let .aborted(message):
            abortMessage = message
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
        let tokenCost = Double(inputTokens) / 1_000_000 * pricing.inputCostPerMillionTokens
            + Double(outputTokens) / 1_000_000 * pricing.outputCostPerMillionTokens
        return tokenCost + Double(webSearches) * Self.costPerWebSearch
    }

    /// Anthropic's published rate: $10 per 1,000 searches.
    static let costPerWebSearch = 0.01

    var spendSummary: String? {
        guard let spend = spendSoFar else { return nil }
        let perTrack = spend / Double(max(checkedCount, 1))
        let total = spend < 0.01 ? "<$0.01" : String(format: "$%.2f", spend)
        let each = String(format: "$%.3f", perTrack)
        return "\(total) so far — \(each) a track, \(webSearches) web search\(webSearches == 1 ? "" : "es")"
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
    func forget(tracks written: [Track]) {
        let ids = Set(written.map(\.id))
        results.removeAll { ids.contains($0.track.id) }
        appliedCount += written.count
        selectedFieldIDs = []
        selectedArtworkIDs = []
    }
}
