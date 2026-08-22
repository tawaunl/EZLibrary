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

/// Reads the intent queue files devices leave in the shared sync folder, and
/// clears them once their changes have been applied.
///
/// The Mac only ever reads and deletes `queue-*.json`; it never writes one, so
/// there is exactly one writer per queue file (the device that owns it) and
/// iCloud never forks a conflict copy.
public enum SnapshotIntentIngestService {
    /// One device's queue as found on disk, paired with its file URL so it can
    /// be removed after its changes are applied.
    public struct DiscoveredQueue: Sendable {
        public let url: URL
        public let queue: SnapshotIntentQueue
    }

    /// Every readable `queue-*.json` in `directory`, oldest first so edits from
    /// a device apply in the order they were made.
    public static func discoverQueues(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [DiscoveredQueue] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let discovered = entries.compactMap { url -> DiscoveredQueue? in
            guard SnapshotIntentQueue.isQueueFileName(url.lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let queue = try? SnapshotIntentQueueCodec.decode(data),
                  queue.schemaVersion <= SnapshotIntentQueue.currentSchemaVersion
            else {
                return nil
            }
            return DiscoveredQueue(url: url, queue: queue)
        }

        return discovered.sorted { $0.queue.generatedAt < $1.queue.generatedAt }
    }

    /// Removes a consumed queue file. Called after its changes are applied so
    /// the same edits aren't offered again on the next check.
    public static func removeQueueFile(at url: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
