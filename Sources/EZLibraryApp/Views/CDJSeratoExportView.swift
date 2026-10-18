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

/// Pick crates and a USB stick, then write a CDJ-readable copy of them.
struct CDJSeratoExportView: View {
    @EnvironmentObject private var libraryService: LibraryService

    @State private var selectedCrateIDs = Set<UUID>()
    @State private var volumes: [URL] = []
    @State private var selectedVolume: URL?
    @State private var maximumCompatibility = true
    @State private var foreignLibrary = false
    @State private var replaceForeignLibrary = false
    @State private var plan: CDJExportPlan?
    @State private var isExporting = false
    @State private var progress: (done: Int, total: Int)?
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var crates: [Crate] {
        libraryService.crates.filter { !$0.trackPaths.isEmpty }
            .sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }
    }

    private var selectedCrates: [Crate] { crates.filter { selectedCrateIDs.contains($0.id) } }
    private var format: CDJStickFormat? { selectedVolume.map { CDJStickFormat.detect(at: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeaderCard(
                    title: "CDJ USB Export",
                    description: "Copy Serato crates to a USB stick that Pioneer CDJs and XDJs can browse. Your Serato library is never changed.",
                    icon: "opticaldiscdrive"
                )
                GroupBox("1. Choose crates") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(crates) { crate in
                            Toggle(isOn: binding(for: crate)) {
                                Text("\(crate.pathComponents.joined(separator: " › "))  (\(crate.trackPaths.count))")
                            }
                        }
                        if crates.isEmpty { Text("No crates with tracks.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox("2. Choose USB stick") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Drive", selection: $selectedVolume) {
                                Text("Select…").tag(URL?.none)
                                ForEach(volumes, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                            }
                            Button("Refresh", action: refreshVolumes)
                        }
                        if let format {
                            if let problem = format.blockingProblem {
                                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
                            } else if let caution = format.caution {
                                Label(caution, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            } else {
                                Label("FAT32 — works on every player.", systemImage: "checkmark.circle").foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(6)
                }
                GroupBox("3. Export") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Maximum CDJ compatibility", isOn: $maximumCompatibility)
                        Text(maximumCompatibility
                            ? "FLAC, M4A, hi-res and unusual-rate audio is converted to 16-bit 44.1 kHz WAV/AIFF so any CDJ can play it."
                            : "Every file is copied exactly as it is. Older players may not play FLAC, M4A or hi-res files.")
                            .font(.caption).foregroundStyle(.secondary)
                        if foreignLibrary {
                            Label(
                                "This stick already has a library that wasn't made by this app, such as one exported from rekordbox. "
                                    + "Exporting replaces its playlists.",
                                systemImage: "exclamationmark.octagon")
                                .foregroundStyle(.red)
                            Toggle("Replace the library on this stick", isOn: $replaceForeignLibrary)
                        }
                        if let plan { planSummary(plan) }
                        Text("Hot cues, loops, beatgrids and waveforms are carried over for MP3, AIFF, WAV, FLAC and M4A.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let progress {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                        if let successMessage { Text(successMessage).foregroundStyle(.green) }
                        Button(isExporting ? "Exporting…" : "Export to USB", action: runExport)
                            .disabled(!canExport)
                    }
                    .padding(6)
                }
            }
            .padding(16)
        }
        .task { refreshVolumes() }
        .onChange(of: selectedCrateIDs) { _, _ in refreshPlan() }
        .onChange(of: selectedVolume) { _, _ in refreshPlan() }
        .onChange(of: maximumCompatibility) { _, _ in refreshPlan() }
        .onChange(of: replaceForeignLibrary) { _, _ in refreshPlan() }
    }

    private var canExport: Bool {
        !isExporting && selectedVolume != nil && !selectedCrateIDs.isEmpty
            && (format?.blockingProblem == nil) && (plan?.items.isEmpty == false)
            && (!foreignLibrary || replaceForeignLibrary)
    }

    @ViewBuilder
    private func planSummary(_ plan: CDJExportPlan) -> some View {
        let size = ByteCountFormatter().string(fromByteCount: Int64(plan.totalBytes))
        Text("\(plan.items.count) tracks, \(size), \(plan.playlists.filter { !$0.isFolder }.count) playlists")
        if plan.convertedCount > 0 {
            Label("\(plan.convertedCount) tracks will be converted, which takes longer and uses more space.", systemImage: "waveform")
        }
        if !plan.refused.isEmpty {
            Label("\(plan.refused.count) tracks can't be put on a stick (surround audio or files over 4 GB) and will be skipped.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if !plan.removals.isEmpty {
            Label(
                "\(plan.removals.count) tracks from an earlier export aren't in the selected crates and will be removed from the stick.",
                systemImage: "trash")
                .foregroundStyle(.orange)
        }
        if !plan.missing.isEmpty {
            Label("\(plan.missing.count) tracks are missing on disk and will be skipped.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if !plan.unsupported.isEmpty {
            Label("\(plan.unsupported.count) tracks are in a format CDJs can't play and will be skipped.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func binding(for crate: Crate) -> Binding<Bool> {
        Binding(
            get: { selectedCrateIDs.contains(crate.id) },
            set: { isOn in
                if isOn { selectedCrateIDs.insert(crate.id) } else { selectedCrateIDs.remove(crate.id) }
            })
    }

    private func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsInternalKey]
        let all = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = all.filter { url in
            url.path.hasPrefix("/Volumes/")
                && (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != true
        }
        if let selectedVolume, !volumes.contains(selectedVolume) { self.selectedVolume = nil }
    }

    private func refreshPlan() {
        successMessage = nil
        errorMessage = nil
        let crates = selectedCrates
        let tracks = libraryService.tracks
        let volume = selectedVolume
        let options = CDJExportOptions(
            maximumCompatibility: maximumCompatibility, replaceForeignLibrary: replaceForeignLibrary)
        plan = nil
        guard !crates.isEmpty else { return }
        Task {
            // Planning is tied to the stick: it keeps track ids stable and spots what to remove.
            let outcome = await Task.detached { () -> (CDJExportPlan?, String?, Bool) in
                var previous: CDJExportManifest?
                var root = "PIONEER"
                var foreign = false
                if let volume {
                    do {
                        let state = try CDJSeratoExport.stickState(at: volume)
                        root = state.root
                        previous = state.manifest
                        foreign = state.foreignLibrary
                    } catch {
                        return (nil, error.localizedDescription, false)
                    }
                }
                let built = CDJSeratoExport.plan(crates: crates, library: tracks, previous: previous, root: root, options: options)
                return (built, nil, foreign)
            }.value
            plan = outcome.0
            errorMessage = outcome.1
            foreignLibrary = outcome.2
        }
    }

    private func runExport() {
        guard let plan, let volume = selectedVolume else { return }
        isExporting = true
        errorMessage = nil
        successMessage = nil
        progress = (0, plan.items.count)
        Task {
            do {
                let result = try await Task.detached {
                    try await CDJSeratoExport.export(plan, to: volume) { done, total in
                        Task { @MainActor in progress = (done, total) }
                    }
                }.value
                successMessage = "Wrote \(result.tracksWritten) tracks and \(result.playlistCount) playlists "
                    + "(\(result.filesCopied) copied, \(result.filesAlreadyOnStick) already on the stick). "
                    + (result.tracksRemoved > 0 ? "\(result.tracksRemoved) removed. " : "")
                    + (result.recoveredInterruptedExport ? "An earlier interrupted export was undone first. " : "")
                    + (result.tracksWithoutSeratoAnalysis > 0
                        ? "\(result.tracksWithoutSeratoAnalysis) tracks had no Serato cues or beatgrid, so they got a waveform only. " : "")
                    + "Eject the stick in Finder before unplugging it."
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
            progress = nil
        }
    }
}
