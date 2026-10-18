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

/// Owns an in-flight library backup at a level above the Backup view.
///
/// The backup used to be a `Task` inside `LibraryBackupView` writing to that
/// view's `@State`. Switching sections tears the view down, so on return the
/// screen showed an idle form — no sign the copy was still going, no result
/// when it finished, and nothing stopping a second backup being started on top
/// of it. Holding the state here keeps the job and its outcome alive across
/// navigation.
@MainActor
final class BackgroundBackupModel: ObservableObject {
    /// Everything the backup needs, snapshotted at start so it doesn't depend
    /// on view state that may be gone by the time it finishes.
    struct Request: Sendable {
        var destinationFolderURL: URL
        var mode: LibraryBackupService.BackupMode
        var tracks: [Track]
        var crates: [Crate]
        var selectedCrateID: UUID?
        var libraryDirectory: URL
        var rootDirectory: URL
    }

    @Published private(set) var isRunning = false
    @Published private(set) var successMessage: String?
    @Published private(set) var errorMessage: String?

    /// Starts a backup. Ignored while one is already running.
    func start(_ request: Request) {
        guard !isRunning else { return }
        isRunning = true
        successMessage = nil
        errorMessage = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.backup(
                        destinationFolderURL: request.destinationFolderURL,
                        mode: request.mode,
                        tracks: request.tracks,
                        crates: request.crates,
                        selectedCrateID: request.selectedCrateID,
                        libraryDirectory: request.libraryDirectory,
                        rootDirectory: request.rootDirectory
                    )
                }.value
                let note = result.note.map { " \($0)" } ?? ""
                successMessage = "Backup created at \(result.backupRootURL.path).\(note)"
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// Dismisses the last result, e.g. when the user reconfigures the backup.
    /// Does nothing mid-run so a result can't be wiped before it arrives.
    func clearResult() {
        guard !isRunning else { return }
        successMessage = nil
        errorMessage = nil
    }
}
