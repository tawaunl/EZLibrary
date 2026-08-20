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

extension Date {
    /// Drops sub-second precision.
    ///
    /// Snapshots and journal entries are compared after a round trip through
    /// ISO 8601 text, which carries whole seconds — so times are truncated on
    /// the way in rather than silently losing precision on the way out. Second
    /// granularity is well beyond what reconciliation at human timescales
    /// needs, and it matches how `LibraryFingerprint` treats file mtimes.
    var truncatedToSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

/// A dated, portable copy of the library's metadata — everything a device
/// away from this Mac needs to browse crates and plan edits, and nothing that
/// requires the audio files themselves.
///
/// Deliberately excludes `Track.id`: that UUID is minted fresh on every parse
/// (see `SeratoDatabaseParser.decodeTrack`), so it means nothing once it
/// leaves the process that created it. Snapshots key tracks by
/// `seratoStoredPath`, which is what Serato itself uses.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    /// Bumped whenever the encoded shape changes incompatibly. A reader that
    /// finds a higher version refuses the file rather than guessing.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// Identifies this snapshot so an intent composed against it can name the
    /// base it assumed. Distinct from `libraryFingerprint`: two snapshots of
    /// an unchanged library share a fingerprint but not an ID.
    public let snapshotID: UUID

    public let generatedAt: Date

    /// Cheap hash of the library's on-disk state at export. Comparing it
    /// against a freshly computed one answers "did anything change since?"
    /// without reparsing.
    public let libraryFingerprint: String

    public let tracks: [SnapshotTrack]
    public let crates: [SnapshotCrate]

    public init(
        schemaVersion: Int = LibrarySnapshot.currentSchemaVersion,
        snapshotID: UUID = UUID(),
        generatedAt: Date = Date(),
        libraryFingerprint: String,
        tracks: [SnapshotTrack],
        crates: [SnapshotCrate]
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotID = snapshotID
        self.generatedAt = generatedAt.truncatedToSeconds
        self.libraryFingerprint = libraryFingerprint
        self.tracks = tracks
        self.crates = crates
    }
}

/// One track as carried in a snapshot.
///
/// `fileURL` is omitted because it is derivable from `storedPath` plus the
/// library root, and the root differs on the device reading the snapshot.
public struct SnapshotTrack: Codable, Sendable, Hashable {
    /// Matches `Track.seratoStoredPath` byte for byte — the identity Serato
    /// and every `.crate` file use.
    public let storedPath: String

    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var comment: String
    public var grouping: String
    public var label: String
    public var year: Int?
    public var duration: TimeInterval?
    public var bitrate: String?
    public var sampleRate: String?
    public var bpm: Double?
    public var key: String?
    public var trackNumber: Int?
    public var dateAdded: Date?
    public var playCount: Int?
    public var isMissing: Bool

    public init(track: Track) {
        self.storedPath = track.seratoStoredPath
        self.title = track.title
        self.artist = track.artist
        self.album = track.album
        self.genre = track.genre
        self.comment = track.comment
        self.grouping = track.grouping
        self.label = track.label
        self.year = track.year
        self.duration = track.duration
        self.bitrate = track.bitrate
        self.sampleRate = track.sampleRate
        self.bpm = track.bpm
        self.key = track.key
        self.trackNumber = track.trackNumber
        self.dateAdded = track.dateAdded
        self.playCount = track.playCount
        self.isMissing = track.isMissing
    }

    /// The value currently stored in `field`, for the fields a remote device
    /// is allowed to edit. Returns `nil` for a field that is unset.
    public func value(for field: TrackField) -> String? {
        switch field {
        case .title: return title.isEmpty ? nil : title
        case .artist: return artist.isEmpty ? nil : artist
        case .album: return album.isEmpty ? nil : album
        case .genre: return genre.isEmpty ? nil : genre
        case .comment: return comment.isEmpty ? nil : comment
        case .key: return key
        case .bpm: return bpm.map { String($0) }
        case .year: return year.map(String.init)
        }
    }
}

/// One crate as carried in a snapshot. Mirrors `Crate` minus the per-parse
/// `id` and the local `fileURL`.
public struct SnapshotCrate: Codable, Sendable, Hashable {
    public let pathComponents: [String]
    public let trackPaths: [String]

    public init(crate: Crate) {
        self.pathComponents = crate.pathComponents
        self.trackPaths = crate.trackPaths
    }

    public init(pathComponents: [String], trackPaths: [String]) {
        self.pathComponents = pathComponents
        self.trackPaths = trackPaths
    }

    public var name: String { pathComponents.last ?? "" }
}

/// The track metadata fields a remote device may edit.
///
/// Pinned to what `SeratoTrackMetadataUpdate` can actually write — `Track`
/// also carries `grouping`, `label`, and `trackNumber`, but there is no write
/// path for them, so a remote device must not offer an edit that has nowhere
/// to land.
public enum TrackField: String, Codable, Sendable, CaseIterable, Hashable {
    case title
    case artist
    case album
    case genre
    case comment
    case key
    case bpm
    case year

    /// Human-readable name for previews and conflict prompts.
    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .comment: return "Comment"
        case .key: return "Key"
        case .bpm: return "BPM"
        case .year: return "Year"
        }
    }
}
