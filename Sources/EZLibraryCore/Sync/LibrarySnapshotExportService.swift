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

/// What one export did.
public struct LibrarySnapshotExport: Sendable, Equatable {
    public let url: URL
    public let trackCount: Int
    public let crateCount: Int

    /// `true` when the library hadn't changed since the last export, so the
    /// existing file was left alone. Re-writing identical bytes would only
    /// churn the sync folder and re-upload the same 2 MB.
    public let wasAlreadyCurrent: Bool

    /// Older snapshots removed to keep the folder tidy.
    public let prunedURLs: [URL]
}

/// Writes library snapshots into a folder a phone can read — normally an
/// iCloud Drive folder, though any synced or removable folder works, since a
/// snapshot is just a file.
///
/// Only this Mac writes files with the `snapshot-` prefix, and the phone only
/// writes `queue-` files, so no file ever has two writers and iCloud has no
/// cause to create conflict copies.
public enum LibrarySnapshotExportService {
    /// Keeps a couple of older snapshots so a device that has been offline
    /// can still find the one its pending work was based on.
    public static let defaultSnapshotsKept = 3

    public static let folderName = "EZLibrary"

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/EZLibrary`, or `nil`
    /// when iCloud Drive isn't set up on this Mac.
    ///
    /// This is the user-visible iCloud Drive folder rather than an app
    /// container on purpose: a container needs an iCloud entitlement, which
    /// needs a provisioning profile, and Gatekeeper refuses to launch an app
    /// whose profile has expired. A plain folder needs none of that, and it
    /// degrades to Dropbox or AirDrop if iCloud isn't wanted.
    public static func defaultDestinationDirectory(fileManager: FileManager = .default) -> URL? {
        let cloudDocs = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard fileManager.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Exports the library, skipping the write when nothing has changed.
    @discardableResult
    public static func export(
        tracks: [Track],
        crates: [Crate],
        libraryDirectory: URL,
        to destinationDirectory: URL,
        keeping snapshotsKept: Int = defaultSnapshotsKept,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> LibrarySnapshotExport {
        let snapshot = LibrarySnapshotBuilder.makeSnapshot(
            tracks: tracks,
            crates: crates,
            libraryDirectory: libraryDirectory,
            generatedAt: generatedAt,
            fileManager: fileManager
        )

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.destinationUnwritable(destinationDirectory.lastPathComponent, error.localizedDescription)
        }

        // Resolved so this matches what `existingSnapshots` reports:
        // directory enumeration returns fully resolved paths, and on macOS the
        // temp and home directories are symlinked, so an unresolved URL would
        // never compare equal to the same file found by listing.
        let destinationURL = destinationDirectory
            .appendingPathComponent(LibrarySnapshotBuilder.fileName(for: snapshot))
            .resolvingSymlinksInPath()

        // The filename carries the library's fingerprint, so an existing file
        // with this name already describes exactly this library state.
        if fileManager.fileExists(atPath: destinationURL.path) {
            return LibrarySnapshotExport(
                url: destinationURL,
                trackCount: snapshot.tracks.count,
                crateCount: snapshot.crates.count,
                wasAlreadyCurrent: true,
                prunedURLs: []
            )
        }

        do {
            _ = try LibrarySnapshotBuilder.write(snapshot, toDirectory: destinationDirectory, fileManager: fileManager)
        } catch {
            throw ExportError.destinationUnwritable(destinationDirectory.lastPathComponent, error.localizedDescription)
        }

        return LibrarySnapshotExport(
            url: destinationURL,
            trackCount: snapshot.tracks.count,
            crateCount: snapshot.crates.count,
            wasAlreadyCurrent: false,
            prunedURLs: prune(in: destinationDirectory, keeping: snapshotsKept, fileManager: fileManager)
        )
    }

    /// Snapshot files in `directory`, newest first.
    public static func existingSnapshots(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .map { $0.resolvingSymlinksInPath() }
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
            .sorted { left, right in
                let leftDate = modificationDate(of: left, fileManager: fileManager)
                let rightDate = modificationDate(of: right, fileManager: fileManager)
                if leftDate == rightDate {
                    // Same second: fall back to the name so ordering is stable
                    // rather than dependent on directory enumeration order.
                    return left.lastPathComponent > right.lastPathComponent
                }
                return leftDate > rightDate
            }
    }

    /// Deletes all but the newest `snapshotsKept` snapshots.
    ///
    /// Non-throwing: a snapshot that can't be deleted is clutter, not a
    /// failure — the export it followed already succeeded.
    @discardableResult
    private static func prune(
        in directory: URL,
        keeping snapshotsKept: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard snapshotsKept > 0 else { return [] }
        let stale = existingSnapshots(in: directory, fileManager: fileManager).dropFirst(snapshotsKept)
        return stale.filter { url in
            (try? fileManager.removeItem(at: url)) != nil
        }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case noICloudDrive
        case destinationUnwritable(String, String)

        public var errorDescription: String? {
            switch self {
            case .noICloudDrive:
                return "iCloud Drive isn't set up on this Mac, so there's nowhere to put the snapshot."
            case let .destinationUnwritable(name, reason):
                return "Couldn't write the library snapshot to \"\(name)\": \(reason)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .noICloudDrive:
                return "Turn on iCloud Drive in System Settings, or choose another folder to export to."
            case .destinationUnwritable:
                return "Pick a folder you can write to, then export again."
            }
        }
    }
}
