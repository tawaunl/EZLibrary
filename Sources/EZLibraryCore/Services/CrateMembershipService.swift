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

/// Adds and removes tracks from a crate.
///
/// Both operations re-read the crate from disk before writing, rather than
/// trusting the copy the UI is holding. A crate shown in the browser may be
/// minutes stale, and writing that back would silently undo anything changed
/// since — a drag, another edit, or Serato itself.
public enum CrateMembershipService {
    public struct Change: Sendable, Equatable {
        public let crateName: String
        /// Tracks actually added or removed. Zero when the crate already
        /// matched what was asked for.
        public let changedCount: Int

        public var didChange: Bool { changedCount > 0 }

        public init(crateName: String, changedCount: Int) {
            self.crateName = crateName
            self.changedCount = changedCount
        }
    }

    public enum MembershipError: Error, LocalizedError {
        case missingCrateFile(String)

        public var errorDescription: String? {
            switch self {
            case let .missingCrateFile(name):
                return "Couldn't find the crate file for \(name)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .missingCrateFile:
                return "Reload the library and try again."
            }
        }
    }

    /// Appends `storedPaths` to `crate`, skipping any it already lists.
    @discardableResult
    public static func add(
        storedPaths: [String],
        to crate: Crate
    ) throws -> Change {
        guard let fileURL = crate.fileURL else {
            throw MembershipError.missingCrateFile(crate.name)
        }

        let latest = try reread(crate, at: fileURL)
        let existing = Set(latest.trackPaths.map(normalize))

        var additions: [String] = []
        var seen = existing
        for path in storedPaths where seen.insert(normalize(path)).inserted {
            additions.append(path)
        }

        guard !additions.isEmpty else {
            return Change(crateName: crate.name, changedCount: 0)
        }

        _ = try SeratoCrateEditor.rewriteTrackPaths(
            in: latest, to: latest.trackPaths + additions)
        return Change(crateName: crate.name, changedCount: additions.count)
    }

    /// Removes `storedPaths` from `crate`. The files stay on disk and in the
    /// library — only this crate's membership changes.
    @discardableResult
    public static func remove(
        storedPaths: [String],
        from crate: Crate
    ) throws -> Change {
        guard let fileURL = crate.fileURL else {
            throw MembershipError.missingCrateFile(crate.name)
        }

        let latest = try reread(crate, at: fileURL)
        let doomed = Set(storedPaths.map(normalize))
        let remaining = latest.trackPaths.filter { !doomed.contains(normalize($0)) }

        let removedCount = latest.trackPaths.count - remaining.count
        guard removedCount > 0 else {
            return Change(crateName: crate.name, changedCount: 0)
        }

        _ = try SeratoCrateEditor.rewriteTrackPaths(in: latest, to: remaining)
        return Change(crateName: crate.name, changedCount: removedCount)
    }

    /// Re-reads the crate, keeping the caller's `fileURL` so the rewrite lands
    /// on the same file the caller meant.
    private static func reread(_ crate: Crate, at fileURL: URL) throws -> Crate {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MembershipError.missingCrateFile(crate.name)
        }
        var latest = try SeratoCrateParser.parseCrate(at: fileURL)
        latest.fileURL = fileURL
        return latest
    }

    /// Crate entries and database entries describe the same file but don't
    /// always agree on separators, a leading slash or case, so membership is
    /// compared the same way `UnfiledTracksService` compares it.
    private static func normalize(_ path: String) -> String {
        UnfiledTracksService.normalize(path)
    }
}
