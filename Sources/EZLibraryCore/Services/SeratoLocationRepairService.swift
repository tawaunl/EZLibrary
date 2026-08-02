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

/// Re-points `location.sqlite` at where files actually live now, for
/// libraries that were moved or renamed by a build that only rewrote
/// `database V2`.
///
/// Serato reads the SQLite library, so those assets all show as missing.
/// Repairing them in place — rather than letting Serato re-import
/// `database V2` and mint fresh rows — is what keeps each track's cues, beat
/// grid, play count and crate membership attached (they hang off `asset.id`).
///
/// `database V2` is treated as the source of truth for current locations,
/// since that's the file the mover kept up to date. Only its tracks that
/// exist on disk are considered, and a stale asset is repaired only when
/// exactly one of them can be it — anything ambiguous is reported for the
/// user to look at rather than guessed.
public enum SeratoLocationRepairService {
    public enum RepairError: Error, LocalizedError {
        case seratoIsRunning
        case noLocationDatabase(URL)
        case noDatabaseV2(URL)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running. Quit Serato before repairing the library index."
            case let .noLocationDatabase(url):
                return "No Serato location database at \(url.path)."
            case let .noDatabaseV2(url):
                return "No database V2 at \(url.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its library on quit, which would revert the repair."
            case .noLocationDatabase:
                return "This library predates Serato's SQLite index — nothing needs repairing."
            case .noDatabaseV2:
                return "Point at a valid _Serato_ folder."
            }
        }
    }

    /// One asset whose path can be corrected without guessing.
    public struct Repair: Sendable, Equatable {
        public let assetID: Int64
        public let oldPortableID: String
        public let newPortableID: String
        /// Where the file actually is now, per `database V2`.
        public let fileURL: URL
    }

    /// An asset that couldn't be repaired, and why — surfaced instead of
    /// resolved so a wrong guess never silently re-points a track.
    public struct Unrepairable: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// No file named like this asset exists anywhere in `database V2`.
            case noCandidate
            /// Several files could be it, and file size didn't break the tie.
            case multipleCandidates(count: Int)
            /// The one candidate is already claimed by a different asset row.
            case destinationTaken(assetID: Int64)
        }

        public let assetID: Int64
        public let portableID: String
        public let reason: Reason
    }

    public struct Plan: Sendable {
        public let libraryDirectory: URL
        /// The database this plan was built against, so `apply` can't end up
        /// writing somewhere else.
        public let locationDatabaseURL: URL
        /// The directory `portable_id` values are relative to, as detected
        /// from this library rather than assumed.
        public let baseDirectory: URL
        /// Directories searched for candidate files, beyond the locations
        /// `database V2` already names.
        public let searchRoots: [URL]
        public let repairs: [Repair]
        /// Assets whose path already resolves to a file on disk.
        public let intactCount: Int
        public let unrepairable: [Unrepairable]

        public var isEmpty: Bool { repairs.isEmpty }
    }

    public struct Result: Sendable, Equatable {
        public let repairedCount: Int
        public let skippedCount: Int
    }

    // MARK: - Planning

    /// Builds a dry-run plan. Reads only — nothing is written until `apply`.
    ///
    /// `searchRoots` widens the candidate pool beyond the files `database V2`
    /// names, which matters because the two can disagree: a real library had
    /// 2931 files in its music folder and only 1663 of them in `database V2`,
    /// leaving hundreds of repairable assets with no candidate. Defaults to
    /// the directories the library's files already live in.
    public static func plan(
        libraryDirectory: URL,
        searchRoots: [URL]? = nil,
        applicationSupportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Plan {
        // The database Serato actually reads, which on 4.x is not the
        // `location.sqlite` sitting inside `_Serato_` — planning against that
        // leftover would report repairs nothing would ever act on.
        guard let locationDatabaseURL = SeratoLocationDatabase.activeDatabases(
            forLibraryDirectory: libraryDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        ).first else {
            throw RepairError.noLocationDatabase(
                SeratoLocationDatabase.locationDatabaseFile(in: libraryDirectory))
        }

        let databaseFileURL = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw RepairError.noDatabaseV2(databaseFileURL)
        }

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: homeDirectory)
        let assets = try SeratoLocationDatabase.assets(in: locationDatabaseURL)
        let destinations = currentFileLocations(
            databaseFileURL: databaseFileURL,
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )

        let baseDirectory = detectBaseDirectory(
            assets: assets,
            candidates: [homeDirectory, rootDirectory, URL(fileURLWithPath: "/", isDirectory: true)],
            fileManager: fileManager
        )

        let resolvedSearchRoots = searchRoots ?? defaultSearchRoots(for: destinations)

        // Serato's own uniqueness rule is case-insensitive, so the filename
        // index has to be too or a repair could collide on apply.
        var destinationsByName: [String: [URL]] = [:]
        var seenPaths = Set<String>()
        func offer(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            destinationsByName[url.lastPathComponent.lowercased(), default: []].append(url)
        }
        destinations.forEach(offer)
        for (_, urls) in FileSystemScanner.scanRoots(resolvedSearchRoots).byFilename {
            urls.forEach(offer)
        }

        let portableIDOwners = Dictionary(
            assets.map { ($0.portableID.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var repairs: [Repair] = []
        var unrepairable: [Unrepairable] = []
        var intactCount = 0
        // Two stale assets pointing at one file is a duplicate-row problem,
        // not something to resolve by letting the last one win.
        var claimedDestinations: [String: Int64] = [:]

        for asset in assets {
            let currentURL = baseDirectory.appendingPathComponent(asset.portableID)
            guard !fileManager.fileExists(atPath: currentURL.path) else {
                intactCount += 1
                continue
            }

            let searchName = asset.fileName.isEmpty
                ? (asset.portableID as NSString).lastPathComponent
                : asset.fileName
            let candidates = destinationsByName[searchName.lowercased()] ?? []

            guard let match = disambiguate(candidates, asset: asset, fileManager: fileManager) else {
                unrepairable.append(
                    Unrepairable(
                        assetID: asset.id,
                        portableID: asset.portableID,
                        reason: candidates.isEmpty ? .noCandidate : .multipleCandidates(count: candidates.count)
                    )
                )
                continue
            }

            let newPortableID = relativePath(of: match, under: baseDirectory)
            guard !newPortableID.isEmpty, newPortableID != asset.portableID else {
                unrepairable.append(
                    Unrepairable(assetID: asset.id, portableID: asset.portableID, reason: .noCandidate)
                )
                continue
            }

            let key = newPortableID.lowercased()
            if let owner = portableIDOwners[key] ?? claimedDestinations[key], owner != asset.id {
                unrepairable.append(
                    Unrepairable(
                        assetID: asset.id,
                        portableID: asset.portableID,
                        reason: .destinationTaken(assetID: owner)
                    )
                )
                continue
            }

            claimedDestinations[key] = asset.id
            repairs.append(
                Repair(
                    assetID: asset.id,
                    oldPortableID: asset.portableID,
                    newPortableID: newPortableID,
                    fileURL: match
                )
            )
        }

        return Plan(
            libraryDirectory: libraryDirectory,
            locationDatabaseURL: locationDatabaseURL,
            baseDirectory: baseDirectory,
            searchRoots: resolvedSearchRoots,
            repairs: repairs.sorted { $0.assetID < $1.assetID },
            intactCount: intactCount,
            unrepairable: unrepairable.sorted { $0.assetID < $1.assetID }
        )
    }

    /// The folders the library's files already live in, per `database V2`.
    /// Narrower and far quicker than a blanket home-directory sweep, and it
    /// automatically points at wherever this particular library was
    /// consolidated to. Falls back to the standard music locations when
    /// `database V2` names nothing that still exists.
    private static func defaultSearchRoots(for destinations: [URL]) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        for directory in destinations.map({ $0.deletingLastPathComponent() }) {
            let path = directory.standardizedFileURL.path
            if seen.insert(path).inserted {
                roots.append(directory)
            }
        }
        guard !roots.isEmpty else { return FileSystemScanner.defaultScanRoots }

        // Drop any root already covered by an ancestor, so a nested folder
        // isn't enumerated twice.
        let sorted = roots.sorted { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
        var kept: [URL] = []
        for root in sorted {
            let path = root.standardizedFileURL.path
            let isNested = kept.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
            if !isNested { kept.append(root) }
        }
        return kept
    }

    // MARK: - Disconnected locations (master.sqlite)

    /// A stale row in a disconnected location, and where its file actually is.
    public struct GhostRepair: Sendable, Equatable {
        public let assetID: Int64
        public let locationID: Int64
        public let oldPortableID: String
        public let newPortableID: String
    }

    public struct GhostPlan: Sendable {
        public let masterDatabaseURL: URL
        public let repairs: [GhostRepair]
        /// Rows whose file couldn't be found anywhere — genuinely deleted
        /// music, left untouched.
        public let unresolvedCount: Int
        /// Rows that would need their `file_name` rewritten, which can't be
        /// done outside Serato (see `SeratoMasterDatabase.rewritePortableIDs`).
        public let needsSeratoRuntimeCount: Int
        public let searchRoots: [URL]

        public var isEmpty: Bool { repairs.isEmpty }
    }

    /// Plans repairs for every location Serato still displays but no longer
    /// syncs — the source of "cannot be located" entries that survive a move.
    ///
    /// Re-pointing these makes each repaired track resolve, but it does not
    /// merge it with the connected location's row for the same file: the same
    /// path then exists under two `location_id`s, which Serato's
    /// `(location_id, portable_id)` unique index permits and which shows up as
    /// a duplicate. Removing the stale location instead is the way to avoid
    /// that; this is here because re-pointing preserves whatever is attached
    /// to the old rows.
    public static func planDisconnectedLocations(
        libraryDirectory: URL,
        searchRoots: [URL]? = nil,
        applicationSupportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> GhostPlan {
        let master = SeratoLocationDatabase.masterDatabaseFile(
            applicationSupportDirectory: applicationSupportDirectory)
        guard fileManager.fileExists(atPath: master.path) else {
            throw RepairError.noLocationDatabase(master)
        }

        let databaseFileURL = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: homeDirectory)
        let destinations = currentFileLocations(
            databaseFileURL: databaseFileURL, rootDirectory: rootDirectory, fileManager: fileManager)
        let resolvedSearchRoots = searchRoots ?? defaultSearchRoots(for: destinations)

        var byName: [String: [URL]] = [:]
        var seenPaths = Set<String>()
        func offer(_ url: URL) {
            guard seenPaths.insert(url.standardizedFileURL.path).inserted else { return }
            byName[url.lastPathComponent.lowercased(), default: []].append(url)
        }
        destinations.forEach(offer)
        for (_, urls) in FileSystemScanner.scanRoots(resolvedSearchRoots).byFilename {
            urls.forEach(offer)
        }

        var repairs: [GhostRepair] = []
        var unresolved = 0
        var needsRuntime = 0

        for locationID in try SeratoMasterDatabase.disconnectedLocationIDs(in: master) {
            for asset in try SeratoMasterDatabase.assets(in: master, locationID: locationID) {
                // Streaming providers register assets under a URI scheme
                // (`streaming:…`) rather than a path. They aren't files, so
                // they're neither broken nor repairable here.
                guard !isStreamingIdentifier(asset.portableID) else { continue }

                // `portable_id` in these rows is relative to the home folder;
                // a row that still resolves needs nothing.
                let current = homeDirectory.appendingPathComponent(asset.portableID)
                guard !fileManager.fileExists(atPath: current.path) else { continue }

                let searchName = asset.fileName.isEmpty
                    ? (asset.portableID as NSString).lastPathComponent
                    : asset.fileName
                let candidates = byName[searchName.lowercased()] ?? []
                guard candidates.count == 1, let match = candidates.first else {
                    unresolved += 1
                    continue
                }

                // Only `portable_id` can be written from outside Serato, so a
                // match whose filename differs is reported, not attempted.
                guard match.lastPathComponent == searchName else {
                    needsRuntime += 1
                    continue
                }

                let newPortableID = relativePath(of: match, under: homeDirectory)
                guard !newPortableID.isEmpty, newPortableID != asset.portableID else {
                    unresolved += 1
                    continue
                }

                repairs.append(
                    GhostRepair(
                        assetID: asset.id,
                        locationID: asset.locationID,
                        oldPortableID: asset.portableID,
                        newPortableID: newPortableID
                    ))
            }
        }

        return GhostPlan(
            masterDatabaseURL: master,
            repairs: repairs.sorted { $0.assetID < $1.assetID },
            unresolvedCount: unresolved,
            needsSeratoRuntimeCount: needsRuntime,
            searchRoots: resolvedSearchRoots
        )
    }

    @discardableResult
    public static func apply(_ plan: GhostPlan) throws -> Result {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RepairError.seratoIsRunning
        }
        guard !plan.repairs.isEmpty else {
            return Result(repairedCount: 0, skippedCount: 0)
        }

        let repaired = try SeratoMasterDatabase.rewritePortableIDs(
            plan.repairs.map { (id: $0.assetID, portableID: $0.newPortableID) },
            in: plan.masterDatabaseURL
        )
        return Result(repairedCount: repaired, skippedCount: plan.repairs.count - repaired)
    }

    // MARK: - Applying

    @discardableResult
    public static func apply(_ plan: Plan) throws -> Result {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RepairError.seratoIsRunning
        }
        guard !plan.repairs.isEmpty else {
            return Result(repairedCount: 0, skippedCount: 0)
        }

        let updates = plan.repairs.map {
            SeratoLocationDatabase.AssetPathUpdate(
                id: $0.assetID,
                portableID: $0.newPortableID,
                fileName: $0.fileURL.lastPathComponent
            )
        }

        let repairedCount = try SeratoLocationDatabase.rewriteAssetPaths(updates, in: plan.locationDatabaseURL)
        return Result(repairedCount: repairedCount, skippedCount: updates.count - repairedCount)
    }

    // MARK: - Helpers

    /// Every `database V2` track that exists on disk right now.
    private static func currentFileLocations(
        databaseFileURL: URL,
        rootDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard let data = try? Data(contentsOf: databaseFileURL) else { return [] }
        return SeratoDatabaseParser.storedPaths(from: data)
            .map { SeratoLibraryLocator.resolve(seratoStoredPath: $0, rootDirectory: rootDirectory) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// `portable_id` is relative to a base that depends on where the library
    /// lives (`$HOME` for a boot-volume library). Rather than assume, score
    /// each candidate against the paths already in the database: first by how
    /// many resolve to a real file, then — for a library so out of date that
    /// none do — by how many at least land in a directory that exists.
    private static func detectBaseDirectory(
        assets: [SeratoLocationDatabase.AssetRecord],
        candidates: [URL],
        fileManager: FileManager
    ) -> URL {
        var uniqueCandidates: [URL] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            uniqueCandidates.append(candidate)
        }

        // A sample is enough to tell the bases apart and keeps the probe from
        // stat-ing a five-figure library twice over.
        let sample = assets.prefix(400)
        guard !sample.isEmpty else { return uniqueCandidates[0] }

        var best = uniqueCandidates[0]
        var bestScore = (files: -1, directories: -1)

        for candidate in uniqueCandidates {
            var files = 0
            var directories = 0
            for asset in sample {
                let url = candidate.appendingPathComponent(asset.portableID)
                if fileManager.fileExists(atPath: url.path) {
                    files += 1
                    directories += 1
                } else {
                    var isDirectory: ObjCBool = false
                    let parent = url.deletingLastPathComponent().path
                    if fileManager.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue {
                        directories += 1
                    }
                }
            }
            if (files, directories) > bestScore {
                bestScore = (files, directories)
                best = candidate
            }
        }

        return best
    }

    /// Narrows same-named candidates by comparing Serato's recorded file size
    /// against what's on disk. Returns `nil` when that still leaves more than
    /// one — better to report the ambiguity than pick.
    private static func disambiguate(
        _ candidates: [URL],
        asset: SeratoLocationDatabase.AssetRecord,
        fileManager: FileManager
    ) -> URL? {
        if candidates.count <= 1 { return candidates.first }
        guard let expectedSize = asset.fileSize else { return nil }

        let sizeMatches = candidates.filter { url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value == expectedSize
        }
        return sizeMatches.count == 1 ? sizeMatches[0] : nil
    }

    /// A `portable_id` that names a streaming track rather than a file — it
    /// carries a URI scheme before the first path separator.
    private static func isStreamingIdentifier(_ portableID: String) -> Bool {
        guard let colon = portableID.firstIndex(of: ":") else { return false }
        let slash = portableID.firstIndex(of: "/")
        return slash.map { colon < $0 } ?? true
    }

    private static func relativePath(of fileURL: URL, under base: URL) -> String {
        var basePath = base.standardizedFileURL.path
        if !basePath.hasSuffix("/") { basePath += "/" }

        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return "" }
        return String(filePath.dropFirst(basePath.count))
    }
}
