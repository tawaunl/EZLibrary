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

/// Picks which verifier runs and reports what each one can do here.
///
/// The three tiers exist because "verify my tags with AI" has to mean something
/// on a 2015 iMac with no API key, not only on the newest hardware with a
/// billing account attached. They are ordered by what they cost the user, not
/// by how clever they are: the free one that works everywhere is the default,
/// and paying for a cloud model is an opt-in for the cases the free tiers
/// genuinely cannot settle.
public enum TagVerificationEngineKind: String, CaseIterable, Sendable {
    /// Cross-source agreement. Free, no key, works on every supported Mac.
    case consensus
    /// Apple's on-device model reasoning over app-supplied database searches.
    /// Free and private, macOS 26 with Apple Intelligence only.
    case onDevice
    /// A cloud model with the user's own API key. Best on the hard tail.
    case cloudModel

    public var displayName: String {
        switch self {
        case .consensus:
            return "Cross-check music databases (free)"
        case .onDevice:
            return "Apple on-device AI (free, private)"
        case .cloudModel:
            return "Cloud AI with your API key"
        }
    }

    public var summary: String {
        switch self {
        case .consensus:
            return "Asks several music databases independently and only proposes a change where they agree. "
                + "No account, no key, no cost. Best all-round choice."
        case .onDevice:
            return "Apple's on-device model reads the database results and judges them. "
                + "Nothing leaves your Mac and there is no cost, but it is a small model — "
                + "expect a few seconds per track and check its proposals."
        case .cloudModel:
            return "Sends each track's tags to a cloud model that can also search the web. "
                + "Strongest on bootlegs, edits, and white labels the databases do not carry. "
                + "Billed to your own account."
        }
    }

    /// True when the tier costs the user money to run.
    public var isPaid: Bool {
        self == .cloudModel
    }
}

public enum TagVerificationCoordinator {
    public static let engineDefaultsKey = "SeratoToolsTagVerificationEngine"

    public struct Availability: Sendable {
        public let kind: TagVerificationEngineKind
        public let isAvailable: Bool
        /// Why it cannot run, when it cannot.
        public let unavailableReason: String?

        public init(kind: TagVerificationEngineKind, isAvailable: Bool, unavailableReason: String?) {
            self.kind = kind
            self.isAvailable = isAvailable
            self.unavailableReason = unavailableReason
        }
    }

    /// How confident a verdict must be before it is trusted without a human
    /// looking at it — used to pre-check proposals in the review sheet and to
    /// gate what the bulk apply will write.
    ///
    /// The tiers do not produce comparable numbers, so one shared constant
    /// would be wrong for at least two of them. Consensus confidence is derived
    /// from how many independent sources agreed, so it means something precise.
    /// The on-device model reports a coarse high/medium/low where "high" lands
    /// at 0.9, so a higher bar there admits only its most certain calls — which
    /// is the intent for a small model.
    public static func confidenceThreshold(for kind: TagVerificationEngineKind) -> Double {
        switch kind {
        case .consensus:
            return 0.75
        case .onDevice:
            return 0.85
        case .cloudModel:
            return 0.75
        }
    }

    /// The bar for writing into a field that is currently **empty**.
    ///
    /// Lower than the bar for replacing a value, and deliberately so: the goal
    /// is a library where artist, album, genre, year, and title are all filled,
    /// and there is nothing to lose by filling a blank from a single source.
    /// Overwriting something the user already has still needs corroboration.
    public static let emptyFieldConfidenceFloor = 0.5

    /// Below this, the engine was unsure it identified the right recording at
    /// all — and a confident verdict about the wrong recording is still wrong,
    /// so none of its field verdicts are auto-trusted.
    public static let identityConfidenceFloor = 0.7

    /// The changes from one verification that are safe to apply without a
    /// human checking them individually.
    ///
    /// `fields` narrows what may be written at all: the bulk apply deliberately
    /// never touches the title, because a title carries the DJ's version
    /// descriptors and rewriting it in bulk is not something to do unreviewed.
    public static func autoApplicableFields(
        in verification: TrackTagVerification,
        engine: TagVerificationEngineKind,
        limitedTo fields: Set<TagIntegrityAudit.Field>,
        onlyFillEmpty: Bool
    ) -> Set<TagIntegrityAudit.Field> {
        guard verification.identityConfidence >= identityConfidenceFloor else { return [] }
        let threshold = confidenceThreshold(for: engine)

        var applicable: Set<TagIntegrityAudit.Field> = []
        for change in verification.proposedChanges where fields.contains(change.field) {
            let isEmpty = change.currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if onlyFillEmpty, !isEmpty { continue }

            // An empty field is filled on weaker evidence than a populated one
            // is overwritten — filling a blank cannot destroy anything.
            let bar = isEmpty ? emptyFieldConfidenceFloor : threshold
            guard change.confidence >= bar else { continue }
            applicable.insert(change.field)
        }
        return applicable
    }

    /// Fills fields an AI engine left blank, using a deterministic cross-source
    /// pass over the same candidates it already searched.
    ///
    /// Completing missing fields is a priority, and a small or cautious model
    /// often returns "unverified" for an empty tag even when the databases it
    /// was shown actually carry a value. This takes that value: for every field
    /// that is currently empty and that the engine did not itself propose for,
    /// it adopts the cross-source consensus answer (at the empty-field floor, so
    /// it clears the bar for filling a blank but not for overwriting anything).
    /// It never touches a populated field and never overrides the engine's own
    /// verdict — it only fills gaps the engine left.
    public static func completingEmptyFields(
        in verification: TrackTagVerification,
        candidates: [OnlineTrackMetadataCandidate]
    ) -> TrackTagVerification {
        guard !candidates.isEmpty else { return verification }

        let track = verification.track
        let alreadyProposed = Set(verification.proposedChanges.map(\.field))
        let consensus = TagConsensusService.consensus(
            for: track,
            fingerprintMatches: [],
            candidates: candidates
        )

        var fields = verification.fields
        var didFill = false
        for field in AITagVerificationService.verifiableFields {
            let current = AITagVerificationService.currentValue(of: field, in: track)
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !alreadyProposed.contains(field) else { continue }
            guard let fill = consensus.fields.first(where: { $0.field == field }),
                  fill.isChange, !fill.proposedValue.isEmpty else { continue }

            let filled = TagFieldVerification(
                field: field,
                verdict: .incorrect,
                currentValue: current,
                proposedValue: fill.proposedValue,
                confidence: max(fill.confidence, emptyFieldConfidenceFloor),
                evidence: "Filled from cross-source lookup — " + fill.evidence
            )
            if let index = fields.firstIndex(where: { $0.field == field }) {
                fields[index] = filled
            } else {
                fields.append(filled)
            }
            didFill = true
        }

        guard didFill else { return verification }
        return TrackTagVerification(
            track: track,
            engineName: verification.engineName,
            identityConfidence: verification.identityConfidence,
            identitySummary: verification.identitySummary,
            fields: fields,
            sourceURLs: verification.sourceURLs,
            webSearchCount: verification.webSearchCount,
            usage: verification.usage,
            artwork: verification.artwork
        )
    }

    public static func availability(of kind: TagVerificationEngineKind) -> Availability {
        switch kind {
        case .consensus:
            // Needs nothing but a network connection, which is why it is the
            // default and the fallback for everything else.
            return Availability(kind: kind, isAvailable: true, unavailableReason: nil)

        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if let error = OnDeviceTagVerificationService.availabilityError {
                    return Availability(
                        kind: kind,
                        isAvailable: false,
                        unavailableReason: error.localizedDescription
                    )
                }
                return Availability(kind: kind, isAvailable: true, unavailableReason: nil)
            }
            return Availability(
                kind: kind,
                isAvailable: false,
                unavailableReason: "Apple's on-device model needs macOS 26 or later."
            )
            #else
            return Availability(
                kind: kind,
                isAvailable: false,
                unavailableReason: "This build was made without Apple's on-device model framework."
            )
            #endif

        case .cloudModel:
            // Asks the service, not Anthropic specifically: with an
            // OpenAI-compatible provider selected there may be no Anthropic key
            // at all, and checking for one reported the tier as unavailable and
            // silently dropped the user back to the free one.
            guard AITagVerificationService.isConfigured() else {
                let provider = AITagVerificationService.selectedProvider()
                let detail = provider == .anthropic
                    ? "Add an Anthropic API key in Settings → API Keys to use a cloud model."
                    : "Set the base URL, model name, and key for your provider in Settings → API Keys."
                return Availability(kind: kind, isAvailable: false, unavailableReason: detail)
            }
            return Availability(kind: kind, isAvailable: true, unavailableReason: nil)
        }
    }

    public static var availableEngines: [Availability] {
        TagVerificationEngineKind.allCases.map(availability(of:))
    }

    /// What a run will actually use, and what the user asked for if those
    /// differ.
    ///
    /// The fallback used to be silent, which is the worst way to fail here: the
    /// user picks the cloud model, the run quietly uses the free cross-check
    /// instead, and nothing anywhere says so. Callers get both values and are
    /// expected to say when they diverge.
    public struct EngineResolution: Sendable {
        public let engine: TagVerificationEngineKind
        /// Set when the stored choice could not run and was substituted.
        public let requested: TagVerificationEngineKind?
        public let fallbackReason: String?

        public var didFallBack: Bool { requested != nil }

        public init(
            engine: TagVerificationEngineKind,
            requested: TagVerificationEngineKind?,
            fallbackReason: String?
        ) {
            self.engine = engine
            self.requested = requested
            self.fallbackReason = fallbackReason
        }
    }

    public static func resolveEngine(userDefaults: UserDefaults = .standard) -> EngineResolution {
        guard let raw = userDefaults.string(forKey: engineDefaultsKey),
              let stored = TagVerificationEngineKind(rawValue: raw) else {
            return EngineResolution(engine: .consensus, requested: nil, fallbackReason: nil)
        }

        let status = availability(of: stored)
        guard !status.isAvailable else {
            return EngineResolution(engine: stored, requested: nil, fallbackReason: nil)
        }
        return EngineResolution(
            engine: .consensus,
            requested: stored,
            fallbackReason: status.unavailableReason
        )
    }

    /// The engine to start on: whatever the user last chose, as long as it can
    /// actually run, and the free universal one otherwise.
    public static func defaultEngine(userDefaults: UserDefaults = .standard) -> TagVerificationEngineKind {
        resolveEngine(userDefaults: userDefaults).engine
    }

    /// The cloud settings the user actually configured.
    ///
    /// Without this a bulk run built `Options()` from scratch and silently used
    /// Anthropic and Opus 5 regardless of the provider and model chosen in
    /// Settings.
    public static func cloudOptionsFromSettings(
        userDefaults: UserDefaults = .standard
    ) -> AITagVerificationService.Options {
        AITagVerificationService.Options(
            provider: AITagVerificationService.selectedProvider(userDefaults: userDefaults),
            model: ClaudeAPIClient.selectedModel(userDefaults: userDefaults)
        )
    }

    /// Runs `kind` over `tracks`, yielding the same events whichever tier does
    /// the work.
    public static func verify(
        tracks: [Track],
        using kind: TagVerificationEngineKind,
        consensusOptions: TagConsensusService.Options = TagConsensusService.Options(),
        cloudOptions: AITagVerificationService.Options = AITagVerificationService.Options()
    ) -> AsyncStream<TagVerificationEvent> {
        switch kind {
        case .consensus:
            return TagConsensusService.verify(tracks: tracks, options: consensusOptions)

        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return OnDeviceTagVerificationService.verify(tracks: tracks)
            }
            #endif
            return aborted(availability(of: .onDevice).unavailableReason ?? "The on-device model is unavailable.")

        case .cloudModel:
            return AITagVerificationService.verify(tracks: tracks, options: cloudOptions)
        }
    }

    private static func aborted(_ message: String) -> AsyncStream<TagVerificationEvent> {
        AsyncStream { continuation in
            continuation.yield(.aborted(message: message))
            continuation.finish()
        }
    }

    /// Roughly how long a run will take, in words.
    ///
    /// Worth showing because the honest answer is sometimes "come back later":
    /// MusicBrainz allows one request a second, so a few thousand tracks is a
    /// genuinely long job, and the on-device model is seconds per track by
    /// nature. A progress count and a Stop button are not much comfort if the
    /// user did not know what they were starting.
    public static func estimatedDurationText(
        for kind: TagVerificationEngineKind,
        trackCount: Int
    ) -> String? {
        guard trackCount > 0 else { return nil }

        let secondsPerTrack: Double
        switch kind {
        case .consensus:
            secondsPerTrack = 0.8
        case .onDevice:
            secondsPerTrack = 12
        case .cloudModel:
            secondsPerTrack = 8
        }

        let total = Double(trackCount) * secondsPerTrack
        guard total >= 60 else { return nil }

        if total < 3600 {
            return "roughly \(Int((total / 60).rounded())) minutes"
        }
        let hours = total / 3600
        return hours < 2 ? "over an hour" : "roughly \(Int(hours.rounded())) hours"
    }

    /// What a run will cost, in words. Free tiers say so plainly rather than
    /// showing "$0.00", which reads like a failed calculation.
    public static func costText(
        for kind: TagVerificationEngineKind,
        trackCount: Int,
        cloudOptions: AITagVerificationService.Options = AITagVerificationService.Options()
    ) -> String {
        switch kind {
        case .consensus:
            return "Free — no account or API key needed."
        case .onDevice:
            return "Free — runs on this Mac, nothing is sent to a paid service."
        case .cloudModel:
            return AITagVerificationService.estimatedCostText(trackCount: trackCount, options: cloudOptions)
                .replacingOccurrences(of: "about", with: "About")
        }
    }
}
