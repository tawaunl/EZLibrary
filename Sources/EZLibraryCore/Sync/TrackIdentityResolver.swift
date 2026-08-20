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

/// How a remote device names a track it wants changed.
///
/// Carries the identifying values the snapshot recorded, not the edited ones,
/// so a queued title change does not chase its own tail when it is resolved.
public struct TrackReference: Codable, Sendable, Hashable {
    public let storedPath: String
    public let title: String
    public let artist: String

    public init(storedPath: String, title: String, artist: String) {
        self.storedPath = storedPath
        self.title = title
        self.artist = artist
    }

    public init(snapshotTrack: SnapshotTrack) {
        self.storedPath = snapshotTrack.storedPath
        self.title = snapshotTrack.title
        self.artist = snapshotTrack.artist
    }
}

/// Matches a track named in an older snapshot against the library as it
/// stands now.
///
/// Track UUIDs are minted per parse and mean nothing across devices, so
/// identity runs on `seratoStoredPath` — which is also what Serato and every
/// `.crate` file use. Paths are not permanent either, so this walks a ladder
/// of increasingly approximate keys and reports which rung answered, letting
/// callers treat an exact hit differently from an inferred one.
public struct TrackIdentityResolver: Sendable {
    /// Which rung of the ladder produced a match, in descending confidence.
    public enum Tier: String, Sendable, Equatable {
        /// The path in the snapshot still exists.
        case exactPath
        /// EZLibrary moved the file itself and recorded where it went.
        case journal
        /// Same filename in a new folder — the shape a consolidation leaves.
        case basename
        /// Same title and artist, corroborating a file that was moved and
        /// renamed by something other than EZLibrary.
        case titleArtist
    }

    public enum Resolution: Sendable, Equatable {
        case resolved(storedPath: String, via: Tier)
        /// More than one track fits and none is clearly right. Surfaced for
        /// the user to settle — never guessed at.
        case ambiguous(candidates: [String], via: Tier)
        case unresolved
    }

    private let pathsInLibrary: Set<String>
    private let pathsByBasename: [String: [String]]
    private let pathsByTitleArtist: [String: [String]]
    private let journal: LibraryChangeJournal

    public init(currentTracks: [Track], journal: LibraryChangeJournal = LibraryChangeJournal()) {
        var paths = Set<String>(minimumCapacity: currentTracks.count)
        var byBasename: [String: [String]] = [:]
        var byTitleArtist: [String: [String]] = [:]

        for track in currentTracks {
            let path = track.seratoStoredPath
            paths.insert(path)
            byBasename[Self.basenameKey(for: path), default: []].append(path)
            if let key = Self.titleArtistKey(title: track.title, artist: track.artist) {
                byTitleArtist[key, default: []].append(path)
            }
        }

        self.pathsInLibrary = paths
        self.pathsByBasename = byBasename
        self.pathsByTitleArtist = byTitleArtist
        self.journal = journal
    }

    public func resolve(_ reference: TrackReference) -> Resolution {
        if pathsInLibrary.contains(reference.storedPath) {
            return .resolved(storedPath: reference.storedPath, via: .exactPath)
        }

        // The journal is exact where it applies: these are moves this app
        // performed and recorded, so there is nothing to infer. It only helps
        // if the destination is still in the library — a file moved and then
        // deleted has to fall through.
        let journalDestination = journal.currentPath(for: reference.storedPath)
        if journalDestination != reference.storedPath, pathsInLibrary.contains(journalDestination) {
            return .resolved(storedPath: journalDestination, via: .journal)
        }

        if let resolution = resolveByBasename(reference) {
            return resolution
        }

        if let key = Self.titleArtistKey(title: reference.title, artist: reference.artist),
           let candidates = pathsByTitleArtist[key] {
            return single(candidates, via: .titleArtist)
        }

        return .unresolved
    }

    /// Consolidation moves files between folders but keeps their names, so a
    /// basename match is the natural next rung. Filenames are not guaranteed
    /// unique, so a collision is corroborated with title and artist before it
    /// is accepted.
    private func resolveByBasename(_ reference: TrackReference) -> Resolution? {
        guard let candidates = pathsByBasename[Self.basenameKey(for: reference.storedPath)] else {
            return nil
        }
        if candidates.count == 1 {
            return .resolved(storedPath: candidates[0], via: .basename)
        }
        guard let key = Self.titleArtistKey(title: reference.title, artist: reference.artist) else {
            return .ambiguous(candidates: candidates.sorted(), via: .basename)
        }
        let corroborated = candidates.filter { pathsByTitleArtist[key]?.contains($0) ?? false }
        if corroborated.count == 1 {
            return .resolved(storedPath: corroborated[0], via: .basename)
        }
        return .ambiguous(candidates: candidates.sorted(), via: .basename)
    }

    private func single(_ candidates: [String], via tier: Tier) -> Resolution {
        candidates.count == 1
            ? .resolved(storedPath: candidates[0], via: tier)
            : .ambiguous(candidates: candidates.sorted(), via: tier)
    }

    // MARK: - Keys

    private static func basenameKey(for path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    /// `nil` when there is nothing to match on — an untitled, unattributed
    /// track must not collide with every other one.
    private static func titleArtistKey(title: String, artist: String) -> String? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTitle.isEmpty || !normalizedArtist.isEmpty else { return nil }
        return "\(normalizedTitle)\u{1F}\(normalizedArtist)"
    }
}
