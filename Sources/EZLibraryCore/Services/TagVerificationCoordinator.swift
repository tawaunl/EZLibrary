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
