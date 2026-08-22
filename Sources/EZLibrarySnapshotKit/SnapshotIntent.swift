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

// MARK: - Track reference

/// How a remote device names a track it wants changed.
///
/// Carries the identifying values the snapshot recorded, not the edited ones,
/// so a queued title change does not chase its own tail when it is resolved
/// against the current library. Lives here (not in `EZLibraryCore`) so the
/// phone can compose intents without any Serato binary-format knowledge; the
/// Mac's `TrackIdentityResolver` consumes the very same type.
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

// MARK: - Intent operation

/// A single change a remote device wants the Mac to make to the real library.
///
/// Deliberately granular: the phone sends *what changed*, never a whole
/// re-exported library, so the Mac can reconcile each edit against its current
/// state and never clobbers work done on the Mac since the snapshot was taken.
public enum SnapshotIntentOperation: Codable, Sendable, Equatable, Hashable {
    /// Edit one field of one track. `oldValue` is the value the snapshot
    /// carried, kept so the Mac can detect a conflicting edit made since.
    case editTrackField(track: TrackReference, field: TrackField, oldValue: String?, newValue: String)
    case createCrate(name: String, parentPathComponents: [String])
    case renameCrate(pathComponents: [String], newName: String)
    case deleteCrate(pathComponents: [String])

    /// One-line description for previews and pending-change lists.
    public var summary: String {
        switch self {
        case let .editTrackField(track, field, _, new):
            let file = (track.storedPath as NSString).lastPathComponent
            return "Edit \(field.displayName) → \"\(new)\" (\(file))"
        case let .createCrate(name, parent):
            return parent.isEmpty
                ? "New crate \"\(name)\""
                : "New crate \"\(name)\" in \"\(parent.last ?? "")\""
        case let .renameCrate(components, new):
            return "Rename \"\(components.last ?? "")\" → \"\(new)\""
        case let .deleteCrate(components):
            return "Delete crate \"\(components.last ?? "")\""
        }
    }
}

// MARK: - Intent operation Codable (explicit, stable on-disk format)

extension SnapshotIntentOperation {
    private enum TypeKey: String, Codable {
        case editTrackField, createCrate, renameCrate, deleteCrate
    }
    private enum CK: String, CodingKey {
        case type, track, field, oldValue, newValue
        case name, parentPathComponents, pathComponents, newName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .editTrackField:
            self = .editTrackField(
                track:    try c.decode(TrackReference.self, forKey: .track),
                field:    try c.decode(TrackField.self, forKey: .field),
                oldValue: try c.decodeIfPresent(String.self, forKey: .oldValue),
                newValue: try c.decode(String.self, forKey: .newValue)
            )
        case .createCrate:
            self = .createCrate(
                name:                 try c.decode(String.self, forKey: .name),
                parentPathComponents: try c.decode([String].self, forKey: .parentPathComponents)
            )
        case .renameCrate:
            self = .renameCrate(
                pathComponents: try c.decode([String].self, forKey: .pathComponents),
                newName:        try c.decode(String.self, forKey: .newName)
            )
        case .deleteCrate:
            self = .deleteCrate(pathComponents: try c.decode([String].self, forKey: .pathComponents))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case let .editTrackField(track, field, old, new):
            try c.encode(TypeKey.editTrackField, forKey: .type)
            try c.encode(track, forKey: .track)
            try c.encode(field, forKey: .field)
            try c.encodeIfPresent(old, forKey: .oldValue)
            try c.encode(new,   forKey: .newValue)
        case let .createCrate(name, parent):
            try c.encode(TypeKey.createCrate, forKey: .type)
            try c.encode(name,   forKey: .name)
            try c.encode(parent, forKey: .parentPathComponents)
        case let .renameCrate(components, newName):
            try c.encode(TypeKey.renameCrate, forKey: .type)
            try c.encode(components,          forKey: .pathComponents)
            try c.encode(newName,             forKey: .newName)
        case let .deleteCrate(components):
            try c.encode(TypeKey.deleteCrate, forKey: .type)
            try c.encode(components,          forKey: .pathComponents)
        }
    }
}

// MARK: - Intent

/// One queued change, tagged with when and against which snapshot it was made.
public struct SnapshotIntent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    /// The snapshot the device was viewing when it composed this — lets the Mac
    /// tell how stale the edit is relative to the current library.
    public let baseSnapshotID: UUID
    public let operation: SnapshotIntentOperation

    public init(id: UUID = UUID(), createdAt: Date = Date(), baseSnapshotID: UUID, operation: SnapshotIntentOperation) {
        self.id = id
        self.createdAt = createdAt.truncatedToWholeSeconds
        self.baseSnapshotID = baseSnapshotID
        self.operation = operation
    }
}

// MARK: - Intent queue (the phone's outbox file)

/// A device's outbox: the pending intents it wants the Mac to apply.
///
/// Written to the shared sync folder as `queue-<deviceID>.json`. Each device
/// owns exactly one queue file keyed by its stable device ID, so no two
/// writers ever touch the same file and iCloud has no cause to fork a conflict
/// copy. The Mac reads these, applies what it can, and deletes the file.
public struct SnapshotIntentQueue: Codable, Sendable, Equatable {
    /// Bumped whenever the encoded shape changes incompatibly.
    public static let currentSchemaVersion = 1

    public static let filePrefix = "queue-"
    public static let fileExtension = "json"

    public let schemaVersion: Int
    /// Stable per-device identifier; also names the file.
    public let deviceID: UUID
    /// Human-readable device label for the Mac's preview ("Tawaun's iPhone").
    public let deviceName: String
    public let generatedAt: Date
    /// The snapshot the queued intents were composed against.
    public let baseSnapshotID: UUID
    public let intents: [SnapshotIntent]

    public init(
        schemaVersion: Int = SnapshotIntentQueue.currentSchemaVersion,
        deviceID: UUID,
        deviceName: String,
        generatedAt: Date = Date(),
        baseSnapshotID: UUID,
        intents: [SnapshotIntent]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.generatedAt = generatedAt.truncatedToWholeSeconds
        self.baseSnapshotID = baseSnapshotID
        self.intents = intents
    }

    /// `queue-<deviceID>.json`, lowercased so it's stable across platforms.
    public var fileName: String {
        "\(Self.filePrefix)\(deviceID.uuidString.lowercased()).\(Self.fileExtension)"
    }

    public static func isQueueFileName(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix(".\(fileExtension)")
    }
}

// MARK: - Queue codec

public enum SnapshotIntentQueueCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ queue: SnapshotIntentQueue) throws -> Data {
        try encoder().encode(queue)
    }

    public static func decode(_ data: Data) throws -> SnapshotIntentQueue {
        try decoder().decode(SnapshotIntentQueue.self, from: data)
    }
}

// MARK: - Applying intents to a snapshot (local preview on either side)

extension LibrarySnapshot {
    /// Returns a new snapshot with all intents applied in order.
    ///
    /// Pure and portable — used by a device to preview its own pending edits
    /// before they are sent, and never touches real audio files.
    public func applying(_ intents: [SnapshotIntent]) -> LibrarySnapshot {
        guard !intents.isEmpty else { return self }

        var trackMap = Dictionary(tracks.map { ($0.storedPath, $0) }, uniquingKeysWith: { first, _ in first })
        var crates = self.crates

        for intent in intents {
            switch intent.operation {
            case let .editTrackField(track, field, _, newValue):
                if var t = trackMap[track.storedPath] {
                    t.apply(field: field, value: newValue)
                    trackMap[track.storedPath] = t
                }

            case let .createCrate(name, parentPathComponents):
                let newPath = parentPathComponents + [name]
                if !crates.contains(where: { $0.pathComponents == newPath }) {
                    crates.append(SnapshotCrate(pathComponents: newPath, trackPaths: []))
                }

            case let .renameCrate(pathComponents, newName):
                crates = crates.map { crate in
                    guard crate.pathComponents.starts(with: pathComponents) else { return crate }
                    let newPath = Array(pathComponents.dropLast()) + [newName]
                        + Array(crate.pathComponents.dropFirst(pathComponents.count))
                    return SnapshotCrate(pathComponents: newPath, trackPaths: crate.trackPaths)
                }

            case let .deleteCrate(pathComponents):
                crates = crates.filter { !$0.pathComponents.starts(with: pathComponents) }
            }
        }

        let orderedTracks = tracks.compactMap { trackMap[$0.storedPath] }
        return LibrarySnapshot(
            schemaVersion:      schemaVersion,
            snapshotID:         snapshotID,
            generatedAt:        generatedAt,
            libraryFingerprint: libraryFingerprint,
            tracks:             orderedTracks,
            crates:             crates
        )
    }
}

extension SnapshotTrack {
    public mutating func apply(field: TrackField, value: String) {
        switch field {
        case .title:   title   = value
        case .artist:  artist  = value
        case .album:   album   = value
        case .genre:   genre   = value
        case .comment: comment = value
        case .key:     key     = value
        case .bpm:     bpm     = Double(value)
        case .year:    year    = Int(value)
        }
    }
}
