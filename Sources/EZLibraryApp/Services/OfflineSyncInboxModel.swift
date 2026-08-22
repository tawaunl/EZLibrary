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

enum OfflineSyncDefaults {
    /// Shared `@AppStorage` key for the sync folder, so the badge model and the
    /// Offline Sync tab always look at the same place.
    static let destinationPathKey = "OfflineSyncDestinationPath"

    /// Resolves the configured sync folder, falling back to the default iCloud
    /// Drive location (then home) when unset — matching `OfflineSyncView`.
    static func resolveDestination(
        storedPath: String = UserDefaults.standard.string(forKey: destinationPathKey) ?? ""
    ) -> URL {
        let trimmed = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed)
        }
        return LibrarySnapshotExportService.defaultDestinationDirectory()
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Watches the sync folder for pending edits queued by phones/tablets and
/// publishes a count for the sidebar badge, so incoming changes surface the
/// moment EZLibrary opens rather than only when the Offline Sync tab is visited.
///
/// Counting only reads the small `queue-*.json` files, never the library, so it
/// is cheap enough to poll and safe to run at launch.
@MainActor
final class OfflineSyncInboxModel: ObservableObject {
    /// Total queued intents across every device — the sidebar badge value.
    @Published private(set) var pendingCount = 0
    /// How many distinct devices have work waiting.
    @Published private(set) var deviceCount = 0

    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 6) {
        self.pollInterval = pollInterval
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let folder = OfflineSyncDefaults.resolveDestination()
        let queues = SnapshotIntentIngestService.discoverQueues(in: folder)
        deviceCount = queues.count
        pendingCount = queues.reduce(0) { $0 + $1.queue.intents.count }
    }
}
