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
import AppKit
import EZLibraryCore

struct LibraryBackupView: View {
    @EnvironmentObject private var libraryService: LibraryService
    @EnvironmentObject private var backupJob: BackgroundBackupModel

    // Remembered across tab switches and launches; empty means "not chosen yet"
    // and falls back to the home folder.
    @AppStorage(BackgroundBackupModel.destinationDefaultsKey) private var destinationPath = ""
    @AppStorage("LibraryBackupMode") private var selectedMode: LibraryBackupService.BackupMode = .full
    @State private var selectedCrateID: UUID?
    // Crate IDs are regenerated on every library load, so the choice is
    // remembered by the crate's file path (or name) instead.
    @AppStorage("LibraryBackupCrateKey") private var savedCrateKey = ""
    @State private var preview: LibraryBackupPreview?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewErrorMessage: String?

    // The backup job lives above this view so it survives a tab switch.
    private var isRunning: Bool { backupJob.isRunning }
    private var successMessage: String? { backupJob.successMessage }
    private var errorMessage: String? { backupJob.errorMessage ?? previewErrorMessage }

    private var availableCrates: [Crate] {
        libraryService.crates + libraryService.smartCrates
    }

    private var destinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var activePreview: LibraryBackupPreview? {
        preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                statsCard
                destinationCard
                if !backupJob.knownDevices.isEmpty {
                    knownDevicesCard
                }
                modeCard
                actionCard
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
            restoreCrateSelection()
            refreshPreview()
        }
        .onChange(of: availableCrates.count) {
            restoreCrateSelection()
            refreshPreview()
        }
        // Reconfiguring the backup retires the last run's banner. This is done
        // here rather than in refreshPreview, which also runs on appearance and
        // would wipe a result that finished while the user was on another tab.
        // The empty/nil -> default transitions are the view re-applying its
        // defaults on appearance, not the user reconfiguring, so they keep it.
        .onChange(of: destinationPath) { old, _ in
            if !old.isEmpty { backupJob.clearResult() }
            refreshPreview()
        }
        .onChange(of: selectedMode) {
            backupJob.clearResult()
            refreshPreview()
        }
        .onChange(of: selectedCrateID) { old, new in
            if old != nil { backupJob.clearResult() }
            if let crate = availableCrates.first(where: { $0.id == new }) {
                savedCrateKey = Self.crateKey(crate)
            }
            refreshPreview()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Create a timestamped SeratoBackups folder at the destination you choose. Full backups copy the whole Serato library and all track files, incremental backups top up new tracks, and single-crate backups package one crate with its tracks.")
                .font(.body)
                .foregroundStyle(.secondary)

            if let notice = backupJob.deviceNotice {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.checkmark")
                    Text(notice).font(.callout)
                    Spacer(minLength: 0)
                    Button("Dismiss") { backupJob.dismissDeviceNotice() }
                        .controlSize(.small)
                }
                .foregroundStyle(.secondary)
            }

            if let successMessage {
                SuccessBanner(message: successMessage) {
                    backupJob.clearResult()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: successMessage)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.16), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .glowCardStyle(radius: 10, opacity: 0.08)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pre-Backup Stats")
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            HStack(spacing: 14) {
                statTag(title: "Tracks", value: "\(activePreview?.trackCount ?? 0)")
                statTag(title: "Crates", value: "\(activePreview?.crateCount ?? 0)")
                statTag(title: "Backup Size", value: activePreview.map { formatBytes($0.estimatedByteCount) } ?? "--")
                Spacer(minLength: 0)
            }

            Text(statsDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .controlBackgroundColor).opacity(0.95), Color(nsColor: .windowBackgroundColor).opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .glowCardStyle(radius: 10, opacity: 0.08)
    }

    private func statTag(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(minWidth: 120, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        )
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Destination")
                .font(.title.weight(.semibold))

            FinderFolderControls(
                label: "Destination folder",
                path: $destinationPath,
                browsePrompt: "Use Folder",
                browseStartURL: destinationURL,
                allowsNewFolderCreation: true,
                onPathChanged: refreshPreview
            )

            Text("SeratoBackups will be created inside: \(destinationURL.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var knownDevicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Known Backup Drives")
                .font(.title3.weight(.semibold))

            Text("Plugging in one of these switches the destination to it automatically. Forgetting a drive only stops that; nothing on the drive is touched.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(backupJob.knownDevices, id: \.volumeUUID) { device in
                let connected = backupJob.connectedDeviceUUIDs.contains(device.volumeUUID)
                HStack(spacing: 10) {
                    Image(systemName: connected ? "externaldrive.fill" : "externaldrive")
                        .foregroundStyle(connected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.body.weight(.medium))
                        Text(
                            (device.relativePath.isEmpty ? "Drive root" : device.relativePath)
                                + " · " + (connected ? "Connected" : "Not connected")
                                + " · last used " + device.lastUsed.formatted(date: .abbreviated, time: .omitted)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Use") { backupJob.use(device) }
                        .controlSize(.small)
                        .disabled(!connected || isRunning)
                        .help("Set the backup destination to this drive.")
                    Button("Forget", role: .destructive) { backupJob.forget(device) }
                        .controlSize(.small)
                        .help("Stop remembering this drive.")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Mode")
                .font(.title3.weight(.semibold))

            Picker("Mode", selection: $selectedMode) {
                ForEach(LibraryBackupService.BackupMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if selectedMode == .singleCrate {
                Picker("Crate", selection: $selectedCrateID) {
                    ForEach(availableCrates) { crate in
                        Text(crate.name.isEmpty ? crate.fileURL?.lastPathComponent ?? "Crate" : crate.name)
                            .tag(Optional(crate.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(availableCrates.isEmpty)

                Text("Packages the selected crate file and the tracks it references.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to back up")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isRunning ? "Backing Up..." : "Create Backup") {
                    runBackup()
                }
                .disabled(isRunning || isActionDisabled)
                .help("Create a timestamped backup copy of your Serato library at the chosen destination.")
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var summaryText: String {
        activePreview.map { preview in
            switch preview.mode {
            case .full:
                return "Will copy \(preview.trackCount) track(s) and the full Serato folder into \(preview.backupRootName)."
            case .incremental:
                return "Will top up the latest backup with new tracks and store it in \(preview.backupRootName)."
            case .singleCrate:
                let crateLabel = preview.crateName ?? "the selected crate"
                return "Will package \(crateLabel) into \(preview.backupRootName)."
            }
        } ?? "Builds a timestamped backup folder before you run it."
    }

    private var statsDetail: String {
        guard let preview = activePreview else {
            return "Choose a destination and backup mode to calculate the backup size."
        }

        switch preview.mode {
        case .full:
            return "Full backups include the whole Serato folder plus your track files."
        case .incremental:
            return "Incremental backups estimate the new track files plus the full Serato folder."
        case .singleCrate:
            return "Single-crate backups package one crate file and the tracks it references."
        }
    }

    private var isActionDisabled: Bool {
        if selectedMode == .singleCrate {
            return availableCrates.isEmpty || selectedCrateID == nil
        }
        return libraryService.tracks.isEmpty
    }

    private static func crateKey(_ crate: Crate) -> String {
        crate.fileURL?.path ?? crate.name
    }

    /// Picks the remembered crate when it still exists, otherwise the first.
    /// Leaves a valid current selection alone.
    private func restoreCrateSelection() {
        if let current = selectedCrateID, availableCrates.contains(where: { $0.id == current }) {
            return
        }
        selectedCrateID = availableCrates.first { Self.crateKey($0) == savedCrateKey }?.id
            ?? availableCrates.first?.id
    }

    private func refreshPreview() {
        previewTask?.cancel()

        previewErrorMessage = nil

        let destination = destinationURL
        let mode = selectedMode
        let crateSelection = selectedCrateID
        let tracks = libraryService.tracks
        let crates = availableCrates
        let libraryDirectory = libraryService.libraryDirectory
        let rootDirectory = libraryService.rootDirectory

        previewTask = Task {
            do {
                let computedPreview = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.preview(
                        destinationFolderURL: destination,
                        mode: mode,
                        tracks: tracks,
                        crates: crates,
                        selectedCrateID: crateSelection,
                        libraryDirectory: libraryDirectory,
                        rootDirectory: rootDirectory
                    )
                }.value

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preview = computedPreview
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preview = nil
                    previewErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runBackup() {
        previewErrorMessage = nil
        backupJob.start(BackgroundBackupModel.Request(
            destinationFolderURL: destinationURL,
            mode: selectedMode,
            tracks: libraryService.tracks,
            crates: availableCrates,
            selectedCrateID: selectedCrateID,
            libraryDirectory: libraryService.libraryDirectory,
            rootDirectory: libraryService.rootDirectory
        ))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GB", gigabytes)
    }
}
