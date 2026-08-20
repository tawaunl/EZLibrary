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

/// Exports a snapshot of the library to a synced folder so it can be browsed
/// on another device while away from this Mac.
struct OfflineSyncView: View {
    @EnvironmentObject private var libraryService: LibraryService

    @State private var destinationPath = ""
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var existingSnapshots: [URL] = []

    private var destinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LibrarySnapshotExportService.defaultDestinationDirectory()
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var iCloudIsAvailable: Bool {
        LibrarySnapshotExportService.defaultDestinationDirectory() != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                statsCard
                destinationCard
                actionCard
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = destinationURL.path
            }
            refreshExistingSnapshots()
        }
        .onChange(of: destinationPath) {
            refreshExistingSnapshots()
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Offline Sync")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("""
                Export a snapshot of your library to a synced folder so you can browse crates \
                and look tracks up on your phone while you're away from this Mac. The snapshot \
                holds metadata only — no audio — so it stays a couple of megabytes.
                """)
                .font(.body)
                .foregroundStyle(.secondary)

            if let successMessage {
                SuccessBanner(message: successMessage) {
                    self.successMessage = nil
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
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Gets Exported")
                .font(.title.weight(.semibold))

            HStack(spacing: 28) {
                statistic(String(libraryService.tracks.count), "tracks")
                statistic(String(libraryService.crates.count), "crates")
                statistic(estimatedSizeText, "estimated size")
            }

            Text("""
                Track titles, artists, albums, BPM, key, and crate contents travel with the \
                snapshot. Your audio files stay exactly where they are.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private func statistic(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Rough, and labelled as such — the real figure depends on how much text
    /// each track carries.
    private var estimatedSizeText: String {
        let bytes = Double(libraryService.tracks.count) * 1_000
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destination")
                .font(.title.weight(.semibold))

            FinderFolderControls(
                label: "Sync folder",
                path: $destinationPath,
                browsePrompt: "Use Folder",
                browseStartURL: destinationURL,
                allowsNewFolderCreation: true,
                onPathChanged: refreshExistingSnapshots
            )

            if iCloudIsAvailable {
                Text("""
                    Defaults to your iCloud Drive, which puts the snapshot on your phone \
                    automatically. Any synced folder works — Dropbox, or somewhere you \
                    AirDrop from.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("""
                    iCloud Drive isn't set up on this Mac, so pick any folder you sync \
                    yourself — the snapshot is an ordinary file.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !existingSnapshots.isEmpty {
                Divider()
                Text("^[\(existingSnapshots.count) snapshot](inflect: true) already here")
                    .font(.callout.weight(.semibold))
                ForEach(existingSnapshots.prefix(3), id: \.self) { url in
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: runExport) {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Export Snapshot")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || libraryService.tracks.isEmpty)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
                .disabled(!FileManager.default.fileExists(atPath: destinationURL.path))
            }

            Text("""
                Exporting again after the library changes writes a new snapshot and clears out \
                the oldest, keeping the most recent few so a device that's been offline can \
                still find the one it was working from.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private func runExport() {
        isExporting = true
        errorMessage = nil
        successMessage = nil

        do {
            let result = try LibrarySnapshotExportService.export(
                tracks: libraryService.tracks,
                crates: libraryService.crates,
                libraryDirectory: libraryService.libraryDirectory,
                to: destinationURL
            )
            successMessage = message(for: result)
        } catch {
            errorMessage = error.localizedDescription
        }

        isExporting = false
        refreshExistingSnapshots()
    }

    private func message(for result: LibrarySnapshotExport) -> String {
        if result.wasAlreadyCurrent {
            return "Your library hasn't changed since the last export, so \(result.url.lastPathComponent) is still current."
        }
        let pruned = result.prunedURLs.isEmpty
            ? ""
            : " Removed \(result.prunedURLs.count) older snapshot\(result.prunedURLs.count == 1 ? "" : "s")."
        return "Exported \(result.trackCount) tracks and \(result.crateCount) crates to \(result.url.lastPathComponent).\(pruned)"
    }

    private func refreshExistingSnapshots() {
        existingSnapshots = LibrarySnapshotExportService.existingSnapshots(in: destinationURL)
    }
}
