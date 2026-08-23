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

/// Review UI for AI tag verification.
///
/// Deliberately a two-stage sheet. The first stage is free and offline: it runs
/// `TagIntegrityAudit` over the selection and offers to narrow the run to the
/// tracks that actually look wrong, because verifying a whole library one
/// request at a time costs real money and most tracks do not need it. The
/// second stage streams verdicts in as they land.
///
/// Nothing is written until the user picks changes and presses Apply — a
/// verdict is a proposal with a source attached, not an instruction.
struct AITagVerificationSheet: View {
    private enum Phase {
        case setup
        case running
        case finished
    }

    let tracks: [Track]
    let onApply: ([(Track, SeratoTrackMetadataUpdate)]) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage(ClaudeAPIClient.modelDefaultsKey) private var modelRawValue = ClaudeModel.opus5.rawValue
    @AppStorage(TagVerificationCoordinator.engineDefaultsKey)
    private var engineRawValue = TagVerificationEngineKind.consensus.rawValue

    @State private var phase: Phase = .setup
    @State private var onlyFlaggedTracks = true
    @State private var useWebSearch = true
    @State private var useFingerprint = true
    @State private var useOnlineCandidates = true
    @State private var showAdvanced = false

    @State private var results: [AITagVerificationService.TrackVerification] = []
    @State private var failures: [(track: Track, message: String)] = []
    @State private var selectedFieldIDs: Set<UUID> = []
    @State private var selectedArtworkIDs: Set<UUID> = []
    @State private var completedCount = 0
    @State private var totalCount = 0
    /// Computed once when the sheet opens rather than per body evaluation:
    /// the audit walks every selected track, and a large selection would
    /// otherwise re-scan on every render.
    @State private var auditFindings: [TagIntegrityAudit.Finding] = []
    @State private var isAuditing = true
    @State private var abortMessage: String?
    @State private var applyErrorMessage: String?
    @State private var appliedSummary: String?
    @State private var runTask: Task<Void, Never>?

    private var model: ClaudeModel {
        ClaudeModel(rawValue: modelRawValue) ?? .opus5
    }

    private var engine: TagVerificationEngineKind {
        TagVerificationEngineKind(rawValue: engineRawValue) ?? .consensus
    }

    private var engineAvailability: TagVerificationCoordinator.Availability {
        TagVerificationCoordinator.availability(of: engine)
    }

    private var consensusOptions: TagConsensusService.Options {
        TagConsensusService.Options(
            useFingerprint: useFingerprint,
            sourceSelection: useOnlineCandidates ? .all : .freeSources
        )
    }

    private var options: AITagVerificationService.Options {
        AITagVerificationService.Options(
            model: model,
            useWebSearch: useWebSearch,
            useFingerprint: useFingerprint,
            useOnlineCandidates: useOnlineCandidates
        )
    }

    private var tracksToVerify: [Track] {
        // With nothing flagged, narrowing would leave nothing to verify and
        // disable the run — but a clean offline pass is not a clean bill of
        // health. The checks catch malformed tags; a well-formed tag naming the
        // wrong recording looks fine to them and is exactly what stage 2 is
        // for. So fall back to the whole selection.
        guard onlyFlaggedTracks, !auditFindings.isEmpty else { return tracks }
        return auditFindings.map(\.track)
    }

    private var canRunSelectedEngine: Bool {
        engineAvailability.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if phase == .setup {
                        setupSection
                    } else {
                        progressSection
                    }

                    if let abortMessage {
                        calloutRow(text: abortMessage, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }

                    if !results.isEmpty {
                        resultsSection
                    }

                    if !failures.isEmpty {
                        failuresSection
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 760, height: 620)
        .task {
            // The offline pass is the free half of the feature, so it runs as
            // soon as the sheet opens — before any key or network is involved.
            let selection = tracks
            auditFindings = await Task.detached(priority: .userInitiated) {
                TagIntegrityAudit.findings(in: selection)
            }.value
            isAuditing = false
        }
        .onDisappear {
            runTask?.cancel()
            runTask = nil
        }
        .alert(
            "Couldn't Apply Changes",
            isPresented: Binding(get: { applyErrorMessage != nil }, set: { if !$0 { applyErrorMessage = nil } })
        ) {
            Button("OK") { applyErrorMessage = nil }
        } message: {
            Text(applyErrorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verify Tags with AI")
                .font(.title2.weight(.semibold))
            Text(
                "Checks each track's tags against its audio fingerprint and the music databases, then proposes "
                + "only the fields a source actually contradicts. Nothing is written until you apply it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if isAuditing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking \(tracks.count) track\(tracks.count == 1 ? "" : "s")…")
                                .font(.callout)
                        }
                    } else {
                        Text(TagIntegrityAudit.summary(for: auditFindings))
                            .font(.callout)
                    }

                    Text(
                        "These checks are free and run offline. They catch empty and placeholder tags, promo text from "
                        + "record pools, tags that disagree with the filename, and keys or BPM values sitting in the genre field."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if !auditFindings.isEmpty, !isAuditing {
                        Toggle(
                            "Only verify the \(auditFindings.count) flagged track\(auditFindings.count == 1 ? "" : "s") "
                            + "(of \(tracks.count) selected)",
                            isOn: $onlyFlaggedTracks
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Skips the tracks that already look fine. This is what keeps a large run affordable.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Step 1 — Free offline checks", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("How to verify", selection: $engineRawValue) {
                        ForEach(TagVerificationEngineKind.allCases, id: \.rawValue) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(engine.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let reason = engineAvailability.unavailableReason {
                        calloutRow(text: reason, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }

                    if engine == .cloudModel {
                        HStack(spacing: 8) {
                            Text("Model")
                                .font(.caption.weight(.semibold))
                            Picker("Model", selection: $modelRawValue) {
                                ForEach(ClaudeModel.allCases, id: \.rawValue) { option in
                                    Text(option.displayName).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                            Spacer(minLength: 0)
                        }

                        Toggle("Search the web to confirm", isOn: $useWebSearch)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help(
                                "Lets the model look up label pages, discographies, and release listings. "
                                + "Turning this off makes runs cheaper but much weaker on remixes, edits, and "
                                + "bootlegs — the tracks the databases get wrong.")
                    }

                    DisclosureGroup("Evidence sources", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Audio fingerprint (AcoustID)", isOn: $useFingerprint)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(
                                    "Identifies the actual audio rather than trusting the tags. "
                                    + "Needs an AcoustID key and fpcalc; skipped automatically if either is missing.")

                            Toggle("Include sources that need a key (Discogs)", isOn: $useOnlineCandidates)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help(
                                    "iTunes, MusicBrainz, and Deezer are always used and need no key. "
                                    + "Turn this on to also consult Discogs, which needs a token but is the "
                                    + "best source for vinyl, bootlegs, and white labels.")
                        }
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)

                    Text(costLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Step 2 — Verify against outside sources", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var costLine: String {
        guard !isAuditing else {
            return "Working out which tracks need verifying…"
        }
        let count = tracksToVerify.count
        guard count > 0 else {
            return "Nothing to verify — no tracks are selected or flagged."
        }
        let estimate = TagVerificationCoordinator.costText(
            for: engine,
            trackCount: count,
            cloudOptions: options
        )
        let unit = engine == .consensus ? "" : ", one request each"
        return "\(count) track\(count == 1 ? "" : "s") will be verified\(unit). \(estimate)"
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if phase == .running {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(progressText)
                    .font(.callout)
                Spacer(minLength: 0)
            }

            if totalCount > 0 {
                ProgressView(value: Double(completedCount), total: Double(totalCount))
            }
        }
    }

    private var progressText: String {
        switch phase {
        case .setup:
            return ""
        case .running:
            let current = min(completedCount + 1, totalCount)
            return "Verifying \(current) of \(totalCount)… each track is searched individually, so this takes a moment."
        case .finished:
            // An aborted run explains itself in its own callout; claiming
            // "0 tracks checked, nothing to change" on top of that reads as a
            // clean bill of health.
            if abortMessage != nil {
                return "The run could not start."
            }
            let changes = totalProposedChanges
            if changes == 0 {
                return "Checked \(results.count) track\(results.count == 1 ? "" : "s") — no field was contradicted by a source."
            }
            return "Checked \(results.count) track\(results.count == 1 ? "" : "s") and found "
                + "\(changes) proposed change\(changes == 1 ? "" : "s")."
        }
    }

    private var totalProposedChanges: Int {
        results.reduce(0) { $0 + $1.proposedChanges.count }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(results) { result in
                if !result.proposedChanges.isEmpty || offersArtwork(result) {
                    resultCard(for: result)
                }
            }

            let confirmedOnly = results.filter { $0.proposedChanges.isEmpty && !offersArtwork(result: $0) }
            if !confirmedOnly.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(confirmedOnly) { result in
                            Text(result.track.fileURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(
                        "\(confirmedOnly.count) track\(confirmedOnly.count == 1 ? "" : "s") confirmed — nothing to change",
                        systemImage: "checkmark.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func resultCard(for result: AITagVerificationService.TrackVerification) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !result.identitySummary.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(result.identitySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        confidenceBadge(result.identityConfidence, label: "ID")
                    }
                }

                // A low identity confidence means the model was unsure it even
                // found the right recording, which makes every field verdict
                // below it worth a second look.
                if result.identityConfidence < 0.6 {
                    calloutRow(
                        text: "Low confidence that this is the right recording — check these before applying.",
                        symbol: "questionmark.circle.fill",
                        tint: .orange
                    )
                }

                ForEach(result.proposedChanges) { change in
                    changeRow(change)
                }

                if let artwork = result.artwork, artwork.fileIsMissingArtwork {
                    artworkRow(artwork)
                }

                HStack(spacing: 6) {
                    Text(result.engineName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if result.webSearchCount > 0 {
                        Text("· \(result.webSearchCount) web search\(result.webSearchCount == 1 ? "" : "es")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(result.track.fileURL.lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func changeRow(_ change: AITagVerificationService.FieldVerification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedFieldIDs.contains(change.id) },
                set: { isOn in
                    if isOn {
                        selectedFieldIDs.insert(change.id)
                    } else {
                        selectedFieldIDs.remove(change.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(change.field.displayName)
                        .font(.caption.weight(.semibold))
                        .frame(width: 52, alignment: .leading)

                    Text(change.currentValue.isEmpty ? "(empty)" : change.currentValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(!change.currentValue.isEmpty)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(change.proposedValue)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                    confidenceBadge(change.confidence, label: nil)
                }

                if !change.evidence.isEmpty {
                    Text(change.evidence)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = change.sourceURL {
                    Link(destination: url) {
                        Text(url.host ?? url.absoluteString)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    /// Only art for a file that has none is offered. Replacing existing cover
    /// art is a taste decision, not a correction, so it does not belong in a
    /// list of things a source says are wrong.
    private func offersArtwork(result: AITagVerificationService.TrackVerification) -> Bool {
        result.artwork?.fileIsMissingArtwork == true
    }

    private func offersArtwork(_ result: AITagVerificationService.TrackVerification) -> Bool {
        offersArtwork(result: result)
    }

    private func artworkRow(_ artwork: ArtworkProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedArtworkIDs.contains(artwork.id) },
                set: { isOn in
                    if isOn {
                        selectedArtworkIDs.insert(artwork.id)
                    } else {
                        selectedArtworkIDs.remove(artwork.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            AsyncImage(url: artwork.url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Artwork")
                        .font(.caption.weight(.semibold))
                        .frame(width: 52, alignment: .leading)
                    Text("(none embedded)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(artwork.sourceName)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                }

                if !artwork.albumTitle.isEmpty {
                    Text("Cover for \(artwork.albumTitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func confidenceBadge(_ confidence: Double, label: String?) -> some View {
        let percent = Int((confidence * 100).rounded())
        let tint: Color = confidence >= 0.85 ? .green : (confidence >= 0.6 ? .orange : .red)
        return Text("\(label.map { "\($0) " } ?? "")\(percent)%")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
            .help("How confident the model is in this verdict.")
    }

    private var failuresSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.track.fileURL.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("\(failures.count) track\(failures.count == 1 ? "" : "s") couldn't be verified", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func calloutRow(text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let appliedSummary {
                Text(appliedSummary)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            if phase == .running {
                Button("Stop") {
                    runTask?.cancel()
                    runTask = nil
                    phase = .finished
                }
                .help("Stop verifying. Results already returned are kept.")
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if phase == .setup {
                Button("Verify \(tracksToVerify.count) Track\(tracksToVerify.count == 1 ? "" : "s")") {
                    startVerification()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAuditing || tracksToVerify.isEmpty || !canRunSelectedEngine)
                .help("Send each track to Claude with its evidence and get back per-field verdicts.")
            } else {
                Button("Apply \(selectedFieldIDs.count) Change\(selectedFieldIDs.count == 1 ? "" : "s")") {
                    applySelectedChanges()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedFieldIDs.isEmpty)
                .help("Write the checked changes to the Serato library and the files' ID3 tags.")
            }
        }
    }

    // MARK: - Actions

    private func startVerification() {
        let targets = tracksToVerify
        guard !targets.isEmpty else { return }

        results = []
        failures = []
        selectedFieldIDs = []
        abortMessage = nil
        appliedSummary = nil
        completedCount = 0
        totalCount = targets.count
        phase = .running

        let cloudOptions = options
        let localOptions = consensusOptions
        let selectedEngine = engine
        runTask = Task {
            let events = TagVerificationCoordinator.verify(
                tracks: targets,
                using: selectedEngine,
                consensusOptions: localOptions,
                cloudOptions: cloudOptions
            )
            for await event in events {
                if Task.isCancelled { break }
                switch event {
                case .started:
                    break
                case let .verified(result):
                    completedCount += 1
                    results.append(result)
                    preselect(result, minimumConfidence: TagVerificationCoordinator.confidenceThreshold(for: selectedEngine))
                case let .failed(track, message):
                    completedCount += 1
                    failures.append((track, message))
                case let .aborted(message):
                    abortMessage = message
                case .finished:
                    break
                }
            }
            phase = .finished
            runTask = nil
        }
    }

    /// Pre-checks the proposals that are safe to trust, and leaves the rest for
    /// the user to opt into. A confident verdict about the wrong recording is
    /// still wrong, so the identity confidence gates this too.
    private func preselect(
        _ result: AITagVerificationService.TrackVerification,
        minimumConfidence: Double
    ) {
        guard result.identityConfidence >= TagVerificationCoordinator.identityConfidenceFloor else { return }
        for change in result.proposedChanges where change.confidence >= minimumConfidence {
            selectedFieldIDs.insert(change.id)
        }
    }

    private func applySelectedChanges() {
        var updates: [(Track, SeratoTrackMetadataUpdate)] = []

        for result in results {
            let fields = Set(
                result.proposedChanges
                    .filter { selectedFieldIDs.contains($0.id) }
                    .map(\.field)
            )
            guard !fields.isEmpty else { continue }
            updates.append((result.track, result.metadataUpdate(applying: fields)))
        }

        guard !updates.isEmpty else { return }

        do {
            try onApply(updates)
            let changeCount = selectedFieldIDs.count
            appliedSummary = "Applied \(changeCount) change\(changeCount == 1 ? "" : "s") "
                + "across \(updates.count) track\(updates.count == 1 ? "" : "s")."
            selectedFieldIDs = []
        } catch {
            applyErrorMessage = error.localizedDescription
        }
    }
}
