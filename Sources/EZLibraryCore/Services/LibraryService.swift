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

/// High-level entry point for loading and managing a Serato library.
@MainActor
public final class LibraryService: ObservableObject {
    @Published public private(set) var tracks: [Track] = [] {
        didSet { revision &+= 1 }
    }
    @Published public private(set) var crates: [Crate] = []
    @Published public private(set) var smartCrates: [Crate] = []
    @Published public private(set) var reloadErrorMessage: String?

    /// Monotonic counter bumped whenever `tracks` is reassigned (reload,
    /// tracks-only reload, or background play-count merge). Views can observe
    /// this cheap `Int` instead of diffing the whole `[Track]` array to know
    /// when to recompute derived data.
    @Published public private(set) var revision: Int = 0

    /// Sorted, deduplicated genres/artist count across `tracks`. Recomputed
    /// once whenever `tracks` is reassigned rather than on every read, since
    /// views were re-deriving these (with a Set + sort) on every body
    /// evaluation while displaying the library.
    @Published public private(set) var trackGenres: [String] = []
    @Published public private(set) var totalArtistCount: Int = 0

    /// Count of distinct track paths across all crates. Recomputed once per
    /// `reload()` — views were re-deriving this with a `Set(flatMap:)` over
    /// every crate on every body evaluation.
    @Published public private(set) var tracksInCratesCount: Int = 0

    @Published public private(set) var libraryDirectory: URL

    /// Background scan that fills each track's `playCount` from its ID3 tag.
    /// Cancelled and restarted whenever `tracks` is reloaded.
    private var playCountLoadTask: Task<Void, Never>?

    /// Monotonic token incremented on each async reload so a slow parse that
    /// finishes after a newer reload started can't overwrite fresher data.
    private var reloadGeneration = 0

    /// Sendable outcome carried back from the off-main parse.
    private enum LoadOutcome: Sendable {
        case loaded(tracks: [Track], crates: [Crate], smartCrates: [Crate])
        case failed(String)
    }

    /// Sendable outcome for a tracks-only off-main parse.
    private enum TracksOutcome: Sendable {
        case loaded([Track])
        case failed(String)
    }

    public init(libraryDirectory: URL = SeratoLibraryLocator.defaultLibraryDirectory) {
        self.libraryDirectory = libraryDirectory
    }

    public var databaseFile: URL {
        SeratoLibraryLocator.databaseFile(in: libraryDirectory)
    }

    public var rootDirectory: URL {
        SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
    }

    public var subcratesDirectory: URL {
        SeratoLibraryLocator.subcratesDirectory(in: libraryDirectory)
    }

    /// Synchronous reload. Parses the whole library on the calling actor;
    /// prefer `reloadAsync()` on the main actor so the parse doesn't block
    /// the UI on large libraries.
    public func reload() throws {
        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        do {
            let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
            let crates = Self.loadCrates(from: SeratoLibraryLocator.subcrateFiles(in: libraryDirectory))
            let smartCrates = Self.loadCrates(from: SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory))
            apply(tracks: tracks, crates: crates, smartCrates: smartCrates)
        } catch {
            applyFailure(error.localizedDescription)
            throw error
        }
    }

    /// Reloads the library with the expensive parse + crate load performed
    /// off the main actor, then publishes the results back on the main actor.
    /// The UI stays responsive throughout, even for 50K-track databases.
    public func reloadAsync() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let libraryDirectory = self.libraryDirectory

        let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
            let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
            let databaseFile = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
            do {
                let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
                let crates = Self.loadCrates(from: SeratoLibraryLocator.subcrateFiles(in: libraryDirectory))
                let smartCrates = Self.loadCrates(from: SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory))
                return .loaded(tracks: tracks, crates: crates, smartCrates: smartCrates)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        // A newer reload was requested while this parse was running — drop
        // this (now stale) result rather than clobbering the fresher one.
        guard generation == reloadGeneration else { return }

        switch outcome {
        case let .loaded(tracks, crates, smartCrates):
            apply(tracks: tracks, crates: crates, smartCrates: smartCrates)
        case let .failed(message):
            applyFailure(message)
        }
    }

    private func apply(tracks: [Track], crates: [Crate], smartCrates: [Crate]) {
        self.tracks = tracks
        self.crates = crates
        self.smartCrates = smartCrates
        reloadErrorMessage = nil
        refreshDerivedTrackStats()
        tracksInCratesCount = Set(crates.lazy.flatMap(\.trackPaths)).count
        loadPlayCounts(for: tracks)
    }

    private func applyFailure(_ message: String) {
        tracks = []
        crates = []
        smartCrates = []
        reloadErrorMessage = message
        refreshDerivedTrackStats()
        tracksInCratesCount = 0
    }

    public func reloadTracksOnly() throws {
        defer { refreshDerivedTrackStats() }

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        do {
            tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
            reloadErrorMessage = nil
            loadPlayCounts(for: tracks)
        } catch {
            tracks = []
            reloadErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Off-main equivalent of `reloadTracksOnly()`: re-parses only the track
    /// database on a background task and publishes it on the main actor, so a
    /// single inline metadata edit doesn't freeze the UI on large libraries.
    /// Crates are left untouched.
    public func reloadTracksOnlyAsync() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let libraryDirectory = self.libraryDirectory

        let outcome = await Task.detached(priority: .userInitiated) { () -> TracksOutcome in
            let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
            let databaseFile = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
            do {
                let tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
                return .loaded(tracks)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        // A newer reload superseded this one while it was parsing.
        guard generation == reloadGeneration else { return }

        switch outcome {
        case let .loaded(tracks):
            self.tracks = tracks
            reloadErrorMessage = nil
            refreshDerivedTrackStats()
            loadPlayCounts(for: tracks)
        case let .failed(message):
            tracks = []
            reloadErrorMessage = message
            refreshDerivedTrackStats()
        }
    }

    private func refreshDerivedTrackStats() {
        trackGenres = Array(Set(tracks.map(\.genre).filter { !$0.isEmpty })).sorted()
        totalArtistCount = Set(tracks.map(\.artist).filter { !$0.isEmpty }).count
    }

    /// Reads each track's play count off the main actor and merges the results
    /// back into `tracks`. Runs in the background because it touches every
    /// audio file's ID3 tag, which is too slow to block a library load.
    private func loadPlayCounts(for snapshot: [Track]) {
        playCountLoadTask?.cancel()

        guard !snapshot.isEmpty else { return }
        let snapshotIDs = snapshot.map(\.id)

        playCountLoadTask = Task.detached(priority: .utility) { [weak self] in
            var counts: [UUID: Int] = [:]
            for track in snapshot {
                if Task.isCancelled { return }
                if let count = SeratoPlayCountReader.playCount(forFileAt: track.fileURL) {
                    counts[track.id] = count
                }
            }

            if Task.isCancelled || counts.isEmpty { return }
            let resolved = counts
            await MainActor.run {
                self?.applyPlayCounts(resolved, forSnapshotIDs: snapshotIDs)
            }
        }
    }

    private func applyPlayCounts(_ counts: [UUID: Int], forSnapshotIDs snapshotIDs: [UUID]) {
        // Only apply when `tracks` hasn't been replaced since the scan started,
        // so a stale background result can't overwrite a newer library load.
        guard tracks.map(\.id) == snapshotIDs else { return }

        tracks = tracks.map { track in
            guard let count = counts[track.id] else { return track }
            var updated = track
            updated.playCount = count
            return updated
        }
    }

    public func setLibraryDirectory(_ newDirectory: URL) {
        libraryDirectory = newDirectory
    }

    /// Parses each crate file and normalizes its `pathComponents` to include
    /// any real-subdirectory nesting on top of the `≫≫`-delimited filename
    /// nesting `SeratoCrateParser` already handles, so both nesting
    /// mechanisms produce one consistent flat path for `CrateHierarchy`.
    ///
    /// `nonisolated` so it can run on the background parse task alongside
    /// `SeratoDatabaseParser`.
    nonisolated private static func loadCrates(from entries: [SeratoLibraryLocator.CrateFileEntry]) -> [Crate] {
        entries.compactMap { entry in
            guard var crate = try? SeratoCrateParser.parseCrate(at: entry.url) else { return nil }
            crate.pathComponents = entry.directoryComponents + crate.pathComponents
            return crate
        }
    }
}
