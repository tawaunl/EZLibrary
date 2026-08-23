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
import Testing
@testable import EZLibraryCore

@Test func theFreeConsensusTierIsAlwaysAvailable() {
    // The whole point of the default tier: it must never be the one that is
    // greyed out, whatever the Mac or the account situation.
    let availability = TagVerificationCoordinator.availability(of: .consensus)
    #expect(availability.isAvailable)
    #expect(availability.unavailableReason == nil)
}

@Test func anUnavailableEngineExplainsItself() {
    for availability in TagVerificationCoordinator.availableEngines where !availability.isAvailable {
        let reason = availability.unavailableReason ?? ""
        #expect(!reason.isEmpty, "\(availability.kind) is unavailable but gives no reason")
    }
}

@Test func theDefaultEngineFallsBackWhenTheStoredChoiceCannotRun() {
    let suite = "CoordinatorTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    #expect(TagVerificationCoordinator.defaultEngine(userDefaults: defaults) == .consensus)

    defaults.set("nonsense", forKey: TagVerificationCoordinator.engineDefaultsKey)
    #expect(TagVerificationCoordinator.defaultEngine(userDefaults: defaults) == .consensus)

    defaults.set(TagVerificationEngineKind.consensus.rawValue, forKey: TagVerificationCoordinator.engineDefaultsKey)
    #expect(TagVerificationCoordinator.defaultEngine(userDefaults: defaults) == .consensus)
}

@Test func onlyTheCloudTierCostsMoney() {
    #expect(!TagVerificationEngineKind.consensus.isPaid)
    #expect(!TagVerificationEngineKind.onDevice.isPaid)
    #expect(TagVerificationEngineKind.cloudModel.isPaid)
}

@Test func freeTiersSayFreeRatherThanShowingZeroDollars() {
    // "$0.00" reads like a failed calculation, not like good news.
    #expect(TagVerificationCoordinator.costText(for: .consensus, trackCount: 500).contains("Free"))
    #expect(TagVerificationCoordinator.costText(for: .onDevice, trackCount: 500).contains("Free"))
    #expect(TagVerificationCoordinator.costText(for: .cloudModel, trackCount: 500).contains("$"))
}

@Test func everyEngineDescribesItself() {
    for kind in TagVerificationEngineKind.allCases {
        #expect(!kind.displayName.isEmpty)
        #expect(kind.summary.count > 40, "\(kind) needs a summary a user can choose from")
    }
}

@Test func anEmptySelectionFinishesWithoutRunningAnything() async {
    var events: [TagVerificationEvent] = []
    for await event in TagVerificationCoordinator.verify(tracks: [], using: .consensus) {
        events.append(event)
    }

    #expect(events.count == 1)
    if case let .finished(verified, failed) = events[0] {
        #expect(verified == 0)
        #expect(failed == 0)
    } else {
        Issue.record("expected a finished event, got \(events[0])")
    }
}

@Test func selectingAnUnavailableEngineAbortsWithItsReason() async {
    let availability = TagVerificationCoordinator.availability(of: .onDevice)
    // Only meaningful on a machine where the on-device model cannot run.
    guard !availability.isAvailable else { return }

    let sample = Track(seratoStoredPath: "a.mp3", fileURL: URL(fileURLWithPath: "/a.mp3"))
    var aborted: [String] = []
    for await event in TagVerificationCoordinator.verify(tracks: [sample], using: .onDevice) {
        if case let .aborted(message) = event {
            aborted.append(message)
        }
    }
    #expect(aborted.count == 1)
}

@Test func providerSelectionDefaultsToAnthropicAndSurvivesBadValues() {
    let suite = "ProviderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    #expect(AITagVerificationService.selectedProvider(userDefaults: defaults) == .anthropic)

    defaults.set("openAICompatible", forKey: AITagVerificationService.providerDefaultsKey)
    #expect(AITagVerificationService.selectedProvider(userDefaults: defaults) == .openAICompatible)

    defaults.set("gpt-nonsense", forKey: AITagVerificationService.providerDefaultsKey)
    #expect(AITagVerificationService.selectedProvider(userDefaults: defaults) == .anthropic)
}

@Test func onlyTheAnthropicProviderClaimsWebSearch() {
    // The distinction matters in the UI: offering a "search the web" toggle
    // for a provider that cannot would be a lie.
    #expect(AITagVerificationService.Provider.anthropic.supportsWebSearch)
    #expect(!AITagVerificationService.Provider.openAICompatible.supportsWebSearch)
}
