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
        for change in verification.proposedChanges
        where fields.contains(change.field) && change.confidence >= threshold {
            if onlyFillEmpty,
               !change.currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            applicable.insert(change.field)
        }
        return applicable
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
            guard ClaudeAPIClient.hasAPIKey() else {
                return Availability(
                    kind: kind,
                    isAvailable: false,
                    unavailableReason: "Add an API key in Settings → API Keys to use a cloud model."
                )
            }
            return Availability(kind: kind, isAvailable: true, unavailableReason: nil)
        }
    }

    public static var availableEngines: [Availability] {
        TagVerificationEngineKind.allCases.map(availability(of:))
    }

    /// The engine to start on: whatever the user last chose, as long as it can
    /// actually run, and the free universal one otherwise.
    public static func defaultEngine(userDefaults: UserDefaults = .standard) -> TagVerificationEngineKind {
        if let raw = userDefaults.string(forKey: engineDefaultsKey),
           let stored = TagVerificationEngineKind(rawValue: raw),
           availability(of: stored).isAvailable {
            return stored
        }
        return .consensus
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
