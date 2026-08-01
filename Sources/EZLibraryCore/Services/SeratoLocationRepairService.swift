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
        /// The directory `portable_id` values are relative to, as detected
        /// from this library rather than assumed.
        public let baseDirectory: URL
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
    public static func plan(
        libraryDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Plan {
        let locationDatabaseURL = SeratoLocationDatabase.locationDatabaseFile(in: libraryDirectory)
        guard fileManager.fileExists(atPath: locationDatabaseURL.path) else {
            throw RepairError.noLocationDatabase(locationDatabaseURL)
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

        // Serato's own uniqueness rule is case-insensitive, so the filename
        // index has to be too or a repair could collide on apply.
        var destinationsByName: [String: [URL]] = [:]
        for destination in destinations {
            destinationsByName[destination.lastPathComponent.lowercased(), default: []].append(destination)
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
            baseDirectory: baseDirectory,
            repairs: repairs.sorted { $0.assetID < $1.assetID },
            intactCount: intactCount,
            unrepairable: unrepairable.sorted { $0.assetID < $1.assetID }
        )
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

        let locationDatabaseURL = SeratoLocationDatabase.locationDatabaseFile(in: plan.libraryDirectory)
        let updates = plan.repairs.map {
            SeratoLocationDatabase.AssetPathUpdate(
                id: $0.assetID,
                portableID: $0.newPortableID,
                fileName: $0.fileURL.lastPathComponent
            )
        }

        let repairedCount = try SeratoLocationDatabase.rewriteAssetPaths(updates, in: locationDatabaseURL)
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

    private static func relativePath(of fileURL: URL, under base: URL) -> String {
        var basePath = base.standardizedFileURL.path
        if !basePath.hasSuffix("/") { basePath += "/" }

        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return "" }
        return String(filePath.dropFirst(basePath.count))
    }
}
