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

// MARK: - What the bulk apply is allowed to write
//
// This gate decides what gets written to a library without anyone looking at it
// field by field, so it is the highest-consequence logic in the feature.

private func verification(
    identityConfidence: Double = 0.95,
    fields: [TagFieldVerification]
) -> TrackTagVerification {
    TrackTagVerification(
        track: Track(seratoStoredPath: "a.mp3", fileURL: URL(fileURLWithPath: "/a.mp3")),
        engineName: "test",
        identityConfidence: identityConfidence,
        identitySummary: "",
        fields: fields
    )
}

private func change(
    _ field: TagIntegrityAudit.Field,
    current: String = "Old",
    proposed: String = "New",
    confidence: Double
) -> TagFieldVerification {
    TagFieldVerification(
        field: field,
        verdict: .incorrect,
        currentValue: current,
        proposedValue: proposed,
        confidence: confidence,
        evidence: ""
    )
}

private let allWritable: Set<TagIntegrityAudit.Field> = [.artist, .album, .genre, .year]

@Test func onlyProposalsAboveTheEngineThresholdAreAutoApplied() {
    let result = verification(fields: [
        change(.album, confidence: 0.9),
        change(.genre, confidence: 0.5)
    ])

    let applied = TagVerificationCoordinator.autoApplicableFields(
        in: result,
        engine: .consensus,
        limitedTo: allWritable,
        onlyFillEmpty: false
    )
    #expect(applied == [.album])
}

@Test func theOnDeviceTierHasAHigherBarThanConsensus() {
    // 0.8 clears the consensus bar but not the on-device one, because a small
    // model's "medium" is not the same evidence as three databases agreeing.
    let result = verification(fields: [change(.album, confidence: 0.8)])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .consensus, limitedTo: allWritable, onlyFillEmpty: false
    ) == [.album])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .onDevice, limitedTo: allWritable, onlyFillEmpty: false
    ).isEmpty)
}

@Test func nothingIsAutoAppliedWhenTheRecordingWasNotConfidentlyIdentified() {
    // Every field verdict is confident, but they are confident *about the wrong
    // recording*, which is the failure mode that silently corrupts a library.
    let result = verification(identityConfidence: 0.4, fields: [
        change(.album, confidence: 0.99),
        change(.year, confidence: 0.99)
    ])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .consensus, limitedTo: allWritable, onlyFillEmpty: false
    ).isEmpty)
}

@Test func theBulkApplyNeverWritesTheTitle() {
    // The title carries version descriptors; rewriting it in bulk without
    // review is not something this path should ever do.
    let result = verification(fields: [
        change(.title, confidence: 0.99),
        change(.album, confidence: 0.99)
    ])

    let applied = TagVerificationCoordinator.autoApplicableFields(
        in: result,
        engine: .consensus,
        limitedTo: allWritable,
        onlyFillEmpty: false
    )
    #expect(!applied.contains(.title))
    #expect(applied.contains(.album))
}

@Test func onlyFillEmptyLeavesPopulatedFieldsAlone() {
    let result = verification(fields: [
        change(.album, current: "Existing Album", confidence: 0.95),
        change(.genre, current: "", confidence: 0.95),
        change(.year, current: "   ", confidence: 0.95)
    ])

    let applied = TagVerificationCoordinator.autoApplicableFields(
        in: result,
        engine: .consensus,
        limitedTo: allWritable,
        onlyFillEmpty: true
    )
    // Whitespace counts as empty; a real value is protected.
    #expect(applied == [.genre, .year])
}

@Test func onlyFillEmptyOffAllowsOverwritingPopulatedFields() {
    let result = verification(fields: [change(.album, current: "Existing", confidence: 0.95)])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .consensus, limitedTo: allWritable, onlyFillEmpty: false
    ) == [.album])
}

@Test func confirmedAndUnverifiedVerdictsAreNeverApplied() {
    let result = verification(fields: [
        TagFieldVerification(
            field: .album, verdict: .correct, currentValue: "Album",
            proposedValue: "", confidence: 0.99, evidence: ""
        ),
        TagFieldVerification(
            field: .genre, verdict: .unverified, currentValue: "",
            proposedValue: "", confidence: 0.99, evidence: ""
        )
    ])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .consensus, limitedTo: allWritable, onlyFillEmpty: false
    ).isEmpty)
}

@Test func shortRunsGiveNoTimeEstimateAndLongOnesDo() {
    // A handful of tracks finishes before a warning would be read.
    #expect(TagVerificationCoordinator.estimatedDurationText(for: .consensus, trackCount: 5) == nil)
    #expect(TagVerificationCoordinator.estimatedDurationText(for: .consensus, trackCount: 0) == nil)

    // A few thousand tracks against a one-request-per-second source is a job
    // the user should be told about before starting it.
    let long = TagVerificationCoordinator.estimatedDurationText(for: .consensus, trackCount: 5000)
    #expect(long?.contains("hour") == true)

    // The on-device model is seconds per track, so it crosses the line sooner.
    #expect(TagVerificationCoordinator.estimatedDurationText(for: .onDevice, trackCount: 10)?.contains("minute") == true)
}

// MARK: - Version descriptors must survive every correction
//
// A DJ owns a specific cut of a record, and the version wording is what
// identifies it. The databases return the plain song title, so a correction
// that is right about the song is still destructive if it drops the version.
// This is enforced at the single point every engine's title change passes
// through, so no engine can bypass it.

private func titleVerification(current: String, proposed: String) -> TrackTagVerification {
    TrackTagVerification(
        track: Track(
            seratoStoredPath: "a.mp3",
            fileURL: URL(fileURLWithPath: "/a.mp3"),
            title: current,
            artist: "Justice"
        ),
        engineName: "test",
        identityConfidence: 0.95,
        identitySummary: "",
        fields: [
            TagFieldVerification(
                field: .title,
                verdict: .incorrect,
                currentValue: current,
                proposedValue: proposed,
                confidence: 0.95,
                evidence: ""
            )
        ]
    )
}

@Test func aCorrectionThatDropsTheVersionHasItRestored() {
    let update = titleVerification(
        current: "Neverendr (Extended Mix)",
        proposed: "Neverender"
    ).metadataUpdate(applying: [.title])

    #expect(update.title == "Neverender (Extended Mix)")
}

@Test func everyCommonDJDescriptorSurvivesACorrection() {
    for descriptor in ["(Extended Mix)", "(Dirty)", "(Clean)", "(Acapella)",
                       "(Radio Edit)", "(Rampa Remix)", "(Intro)", "(Instrumental)"] {
        let update = titleVerification(
            current: "Sng \(descriptor)",
            proposed: "Song"
        ).metadataUpdate(applying: [.title])

        #expect(update.title == "Song \(descriptor)", "lost \(descriptor)")
    }
}

@Test func aDescriptorAlreadyOnTheProposalIsNotDuplicated() {
    let update = titleVerification(
        current: "Song (Extended Mix)",
        proposed: "Song (Extended Mix)"
    ).metadataUpdate(applying: [.title])

    #expect(update.title == "Song (Extended Mix)")
}

@Test func aTitleWithNoDescriptorIsCorrectedNormally() {
    let update = titleVerification(current: "Nevrender", proposed: "Neverender")
        .metadataUpdate(applying: [.title])
    #expect(update.title == "Neverender")
}

// MARK: - Filling every field

@Test func anEmptyFieldIsFilledOnWeakerEvidenceThanAnOverwrite() {
    // The goal is a library with all five fields populated, and filling a blank
    // from one source cannot destroy anything.
    let emptyField = verification(fields: [
        change(.genre, current: "", proposed: "House", confidence: 0.5)
    ])
    let populatedField = verification(fields: [
        change(.genre, current: "Techno", proposed: "House", confidence: 0.5)
    ])

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: emptyField, engine: .consensus,
        limitedTo: [.title, .artist, .album, .genre, .year], onlyFillEmpty: false
    ) == [.genre])

    // Replacing a value the user already has still needs corroboration.
    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: populatedField, engine: .consensus,
        limitedTo: [.title, .artist, .album, .genre, .year], onlyFillEmpty: false
    ).isEmpty)
}

@Test func aWeakProposalStillCannotFillAnEmptyField() {
    // "Lower bar" is not "no bar" — a near-guess is still refused.
    let result = verification(fields: [
        change(.genre, current: "", proposed: "House", confidence: 0.3)
    ])
    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result, engine: .consensus,
        limitedTo: [.genre], onlyFillEmpty: false
    ).isEmpty)
}

@Test func allFiveFieldsCanBeFilledInOnePass() {
    let result = verification(fields: [
        change(.title, current: "", proposed: "Neverender", confidence: 0.9),
        change(.artist, current: "", proposed: "Justice", confidence: 0.9),
        change(.album, current: "", proposed: "Hyperdrama", confidence: 0.9),
        change(.genre, current: "", proposed: "Electronic", confidence: 0.6),
        change(.year, current: "", proposed: "2024", confidence: 0.75)
    ])

    let applied = TagVerificationCoordinator.autoApplicableFields(
        in: result,
        engine: .consensus,
        limitedTo: [.title, .artist, .album, .genre, .year],
        onlyFillEmpty: false
    )
    #expect(applied == [.title, .artist, .album, .genre, .year])
}
