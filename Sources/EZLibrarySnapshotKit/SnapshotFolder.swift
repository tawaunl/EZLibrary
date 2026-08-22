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

/// Finds snapshots in the folder the Mac exports into.
///
/// The Mac writes `snapshot-<fingerprint>.json` and nothing else with that
/// prefix, so a device can pick the newest without opening any of them. Keeping
/// this here rather than in the app means it is covered by `swift test` and
/// compiled for iOS by CI.
public enum SnapshotFolder {
    /// The folder name `LibrarySnapshotExportService` creates inside iCloud
    /// Drive. Devices look for this so the user picks a recognisable folder.
    public static let defaultFolderName = "EZLibrary"

    public static let snapshotPrefix = "snapshot-"

    /// Snapshot files in `directory`, newest first.
    ///
    /// Ordering is by modification date, falling back to the file name so two
    /// snapshots written in the same second still order deterministically
    /// rather than by directory enumeration order.
    public static func snapshots(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.lastPathComponent.hasPrefix(snapshotPrefix) && $0.pathExtension == "json" }
            .sorted { left, right in
                let leftDate = modificationDate(of: left, fileManager: fileManager)
                let rightDate = modificationDate(of: right, fileManager: fileManager)
                if leftDate == rightDate {
                    return left.lastPathComponent > right.lastPathComponent
                }
                return leftDate > rightDate
            }
    }

    /// Loads the newest snapshot in `directory`, prepared for browsing.
    public static func loadNewest(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> SnapshotLibrary {
        guard let newest = snapshots(in: directory, fileManager: fileManager).first else {
            throw FolderError.noSnapshots(directory.lastPathComponent)
        }
        return SnapshotLibrary(snapshot: try LibrarySnapshotBuilder.read(contentsOf: newest))
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    public enum FolderError: Error, LocalizedError, Equatable {
        case noSnapshots(String)

        public var errorDescription: String? {
            switch self {
            case let .noSnapshots(name):
                return "No library snapshots were found in \"\(name)\"."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .noSnapshots:
                return "On your Mac, open EZLibrary, go to Offline Sync, and tap Export Snapshot."
            }
        }
    }
}
