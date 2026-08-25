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

/// Removes *provably dead* disconnected locations from Serato's `master.sqlite`.
///
/// A location Serato no longer syncs (no `connection` row) keeps aggregating
/// its assets into `master.sqlite` forever — the "cannot be located" clutter
/// that survives library migrations and reorganizations. This prunes only the
/// ones that are safe to remove without ever touching a drive that is merely
/// offline:
///
/// - **Streaming** locations (Spotify etc.) — their assets are URIs, not
///   files, so there is no drive to come back.
/// - **File** locations whose every asset is missing on disk *and* names no
///   external volume — a superseded boot-volume leftover.
///
/// A location is deliberately **kept** when any of its files still resolve
/// (it's live), when it references a `/Volumes/…` path (it could be an
/// unplugged external drive), or when the user set Serato's "keep in library
/// when disconnected" flag. Removal is a cascade delete (see
/// `SeratoMasterDatabase.deleteLocations`), which is backed up first and does
/// not fire Serato's runtime-only triggers.
public enum SeratoDeadLocationSweeper {
    public struct DeadLocation: Sendable, Equatable {
        public enum Reason: String, Sendable {
            /// The location had no assets at all.
            case empty
            /// Every asset is a streaming URI, not a file.
            case streamingOnly
            /// Every file asset is missing on disk and names no external volume.
            case allFilesMissing
        }

        public let locationID: Int64
        public let assetCount: Int
        public let reason: Reason

        public init(locationID: Int64, assetCount: Int, reason: Reason) {
            self.locationID = locationID
            self.assetCount = assetCount
            self.reason = reason
        }
    }

    public struct Plan: Sendable {
        public let masterDatabaseURL: URL
        public let dead: [DeadLocation]
        /// Disconnected locations left alone (live files, external volume, or
        /// user chose to keep them visible offline).
        public let keptDisconnectedIDs: [Int64]

        public var isEmpty: Bool { dead.isEmpty }
        public var removableAssetCount: Int { dead.reduce(0) { $0 + $1.assetCount } }

        public init(masterDatabaseURL: URL, dead: [DeadLocation], keptDisconnectedIDs: [Int64]) {
            self.masterDatabaseURL = masterDatabaseURL
            self.dead = dead
            self.keptDisconnectedIDs = keptDisconnectedIDs
        }
    }

    public struct Summary: Sendable, Equatable {
        public let removedLocationCount: Int
        public let removedAssetCount: Int

        public static let none = Summary(removedLocationCount: 0, removedAssetCount: 0)

        public init(removedLocationCount: Int, removedAssetCount: Int) {
            self.removedLocationCount = removedLocationCount
            self.removedAssetCount = removedAssetCount
        }
    }

    public enum SweepError: Error, Equatable {
        case seratoIsRunning
    }

    /// Classifies every disconnected location without changing anything.
    public static func plan(
        applicationSupportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Plan {
        let master = SeratoLocationDatabase.masterDatabaseFile(
            applicationSupportDirectory: applicationSupportDirectory)
        guard fileManager.fileExists(atPath: master.path) else {
            return Plan(masterDatabaseURL: master, dead: [], keptDisconnectedIDs: [])
        }

        var dead: [DeadLocation] = []
        var kept: [Int64] = []

        for location in try SeratoMasterDatabase.disconnectedLocations(in: master) {
            // Honor the user's "keep in library when disconnected" choice.
            guard !location.showWhenDisconnected else {
                kept.append(location.id)
                continue
            }

            let assets = try SeratoMasterDatabase.assets(in: master, locationID: location.id)
            if let reason = classify(assets, homeDirectory: homeDirectory, fileManager: fileManager) {
                dead.append(DeadLocation(locationID: location.id, assetCount: assets.count, reason: reason))
            } else {
                kept.append(location.id)
            }
        }

        return Plan(
            masterDatabaseURL: master,
            dead: dead.sorted { $0.locationID < $1.locationID },
            keptDisconnectedIDs: kept.sorted())
    }

    /// Deletes the locations classified dead by `plan`. No-op when empty.
    @discardableResult
    public static func apply(_ plan: Plan) throws -> Summary {
        guard !plan.dead.isEmpty else { return .none }
        guard !SeratoProcessGuard.isSeratoRunning else { throw SweepError.seratoIsRunning }

        let removed = try SeratoMasterDatabase.deleteLocations(
            plan.dead.map(\.locationID), in: plan.masterDatabaseURL)
        return Summary(removedLocationCount: removed, removedAssetCount: plan.removableAssetCount)
    }

    /// Convenience: `plan` then `apply`.
    @discardableResult
    public static func sweep(
        applicationSupportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Summary {
        try apply(plan(
            applicationSupportDirectory: applicationSupportDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager))
    }

    // MARK: - Classification

    /// The reason a location is safe to remove, or `nil` to keep it.
    static func classify(
        _ assets: [SeratoMasterDatabase.AssetRecord],
        homeDirectory: URL,
        fileManager: FileManager
    ) -> DeadLocation.Reason? {
        guard !assets.isEmpty else { return .empty }

        var sawFileAsset = false
        for asset in assets {
            if isStreamingIdentifier(asset.portableID) { continue }
            sawFileAsset = true

            // An external-volume reference could be a drive that is merely
            // unplugged — never remove those automatically.
            if referencesExternalVolume(asset.portableID) { return nil }

            // If any file still resolves, the location is live: keep it.
            if resolvedURLs(for: asset.portableID, homeDirectory: homeDirectory)
                .contains(where: { fileManager.fileExists(atPath: $0.path) }) {
                return nil
            }
        }

        return sawFileAsset ? .allFilesMissing : .streamingOnly
    }

    /// Where a disconnected location's `portable_id` might resolve. Serato has
    /// stored these relative to `$HOME`, relative to `/`, and as absolute
    /// paths across versions, so all are tried before calling a file missing.
    static func resolvedURLs(for portableID: String, homeDirectory: URL) -> [URL] {
        guard !portableID.isEmpty else { return [] }
        if portableID.hasPrefix("/") {
            return [URL(fileURLWithPath: portableID)]
        }
        return [
            homeDirectory.appendingPathComponent(portableID),
            URL(fileURLWithPath: "/").appendingPathComponent(portableID)
        ]
    }

    static func referencesExternalVolume(_ portableID: String) -> Bool {
        portableID.hasPrefix("/Volumes/") || portableID.hasPrefix("Volumes/")
    }

    /// A `portable_id` that names a streaming track rather than a file — it
    /// carries a URI scheme before the first path separator.
    static func isStreamingIdentifier(_ portableID: String) -> Bool {
        guard let colon = portableID.firstIndex(of: ":") else { return false }
        let slash = portableID.firstIndex(of: "/")
        return slash.map { colon < $0 } ?? true
    }
}
