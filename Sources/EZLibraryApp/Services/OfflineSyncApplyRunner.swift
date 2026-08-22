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
import EZLibraryCore

/// Applies incoming device edits from the sync folder in one pass — discover,
/// reconcile, apply the accepted ones through the real write path, drop the
/// consumed queues, and reload. Shared by the launch prompt (apply everything
/// that's ready) and the Offline Sync tab (apply the user's selection), so
/// there's one apply path rather than two that can drift.
@MainActor
enum OfflineSyncApplyRunner {
    struct Outcome {
        var applied = 0
        var conflictsRemaining = 0
        var unresolvedRemaining = 0
        var failures: [String] = []
    }

    /// Applies every reconciled change for which `accepting` returns true and
    /// that is actually applyable. A queue file is removed once it has no
    /// applyable change left unhandled.
    static func apply(
        folder: URL,
        libraryService: LibraryService,
        accepting: (IncomingChange) -> Bool
    ) async -> Outcome {
        let discovered = SnapshotIntentIngestService.discoverQueues(in: folder)
        let plan = SnapshotIntentReconciler.plan(
            queues: discovered.map(\.queue),
            tracks: libraryService.tracks,
            crates: libraryService.crates,
            journal: LibraryChangeJournal()
        )

        var outcome = Outcome()
        let toApply = plan.filter { $0.isApplyable && accepting($0) }
        for change in toApply {
            guard let resolved = change.resolved else { continue }
            do {
                try SnapshotIntentApplier.apply(
                    resolved,
                    tracks: libraryService.tracks,
                    crates: libraryService.crates,
                    libraryDirectory: libraryService.libraryDirectory
                )
                outcome.applied += 1
            } catch {
                outcome.failures.append("\(change.summary): \(error.localizedDescription)")
            }
        }

        let appliedIDs = Set(toApply.map(\.id))
        for queue in discovered {
            let stillActionable = queue.queue.intents.contains { intent in
                guard let change = plan.first(where: { $0.id == intent.id }) else { return false }
                return change.isApplyable && !appliedIDs.contains(change.id)
            }
            if !stillActionable {
                try? SnapshotIntentIngestService.removeQueueFile(at: queue.url)
            }
        }

        for change in plan where !appliedIDs.contains(change.id) {
            switch change.status {
            case .conflict: outcome.conflictsRemaining += 1
            case .unresolved: outcome.unresolvedRemaining += 1
            default: break
            }
        }

        if outcome.applied > 0 {
            await libraryService.reloadAsync()
        }
        return outcome
    }
}
