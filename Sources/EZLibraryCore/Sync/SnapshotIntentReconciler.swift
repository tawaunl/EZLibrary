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

/// A single incoming change from a remote device, resolved against the current
/// library and classified so the Mac can preview it before touching anything.
public struct IncomingChange: Identifiable, Sendable, Equatable {
    /// The originating intent's id — stable, so the UI can track a row.
    public let id: UUID
    public let deviceID: UUID
    public let deviceName: String
    public let summary: String
    public let status: Status
    /// Present when the change resolved to a concrete operation the applier can
    /// perform. `nil` only for `.unresolved`.
    public let resolved: ResolvedOperation?

    public enum Status: Sendable, Equatable {
        /// Ready to apply cleanly.
        case applicable
        /// The Mac's current value differs from what the device started from,
        /// so applying would overwrite a change made here since. Still
        /// applicable if the user chooses to.
        case conflict(String)
        /// The target track or crate could not be found in the current library.
        case unresolved(String)
        /// The library already matches the requested state — nothing to do.
        case redundant
    }

    public var isApplyable: Bool {
        switch status {
        case .applicable, .conflict: return resolved != nil
        case .unresolved, .redundant: return false
        }
    }
}

/// A change resolved to a concrete operation against the current library.
public enum ResolvedOperation: Sendable, Equatable {
    case editTrackField(storedPath: String, field: TrackField, newValue: String, currentValue: String?)
    case createCrate(pathComponents: [String])
    case renameCrate(fromPathComponents: [String], newName: String)
    case deleteCrate(pathComponents: [String])
}

/// Turns a set of device queues into a reviewable plan by resolving every
/// intent against the library as it stands now. Pure — it reads nothing from
/// disk and writes nothing; `SnapshotIntentApplier` performs the accepted work.
public enum SnapshotIntentReconciler {
    public static func plan(
        queues: [SnapshotIntentQueue],
        tracks: [Track],
        crates: [Crate],
        journal: LibraryChangeJournal = LibraryChangeJournal()
    ) -> [IncomingChange] {
        let resolver = TrackIdentityResolver(currentTracks: tracks, journal: journal)
        let tracksByStoredPath = Dictionary(tracks.map { ($0.seratoStoredPath, $0) }, uniquingKeysWith: { first, _ in first })
        let cratePaths = Set(crates.map { $0.pathComponents })

        var changes: [IncomingChange] = []
        for queue in queues {
            for intent in queue.intents {
                changes.append(
                    resolve(
                        intent: intent,
                        queue: queue,
                        resolver: resolver,
                        tracksByStoredPath: tracksByStoredPath,
                        crates: crates,
                        cratePaths: cratePaths
                    )
                )
            }
        }
        return changes
    }

    private static func resolve(
        intent: SnapshotIntent,
        queue: SnapshotIntentQueue,
        resolver: TrackIdentityResolver,
        tracksByStoredPath: [String: Track],
        crates: [Crate],
        cratePaths: Set<[String]>
    ) -> IncomingChange {
        func make(_ status: IncomingChange.Status, _ resolved: ResolvedOperation?) -> IncomingChange {
            IncomingChange(
                id: intent.id,
                deviceID: queue.deviceID,
                deviceName: queue.deviceName,
                summary: intent.operation.summary,
                status: status,
                resolved: resolved
            )
        }

        switch intent.operation {
        case let .editTrackField(track, field, oldValue, newValue):
            switch resolver.resolve(track) {
            case let .resolved(storedPath, _):
                let current = tracksByStoredPath[storedPath].flatMap { value(of: field, in: $0) }
                if current == newValue {
                    return make(.redundant, nil)
                }
                let resolved = ResolvedOperation.editTrackField(
                    storedPath: storedPath, field: field, newValue: newValue, currentValue: current
                )
                // The device started from `oldValue`; if the Mac no longer
                // shows that, someone edited it here in the meantime.
                if let oldValue, current != oldValue {
                    return make(.conflict("This Mac shows \(display(current)) for \(field.displayName)"), resolved)
                }
                if oldValue == nil, let current, !current.isEmpty {
                    return make(.conflict("This Mac already shows \(display(current)) for \(field.displayName)"), resolved)
                }
                return make(.applicable, resolved)

            case .ambiguous:
                return make(.unresolved("Matches more than one track in your library"), nil)
            case .unresolved:
                return make(.unresolved("That track isn't in your library anymore"), nil)
            }

        case let .createCrate(name, parent):
            let path = parent + [name]
            if cratePaths.contains(path) {
                return make(.redundant, nil)
            }
            return make(.applicable, .createCrate(pathComponents: path))

        case let .renameCrate(pathComponents, newName):
            let affected = crates.filter { $0.pathComponents.starts(with: pathComponents) }
            if affected.isEmpty {
                return make(.unresolved("That crate isn't in your library anymore"), nil)
            }
            let destination = Array(pathComponents.dropLast()) + [newName]
            if cratePaths.contains(destination) {
                return make(.conflict("A crate named \"\(newName)\" already exists here"),
                            .renameCrate(fromPathComponents: pathComponents, newName: newName))
            }
            return make(.applicable, .renameCrate(fromPathComponents: pathComponents, newName: newName))

        case let .deleteCrate(pathComponents):
            let affected = crates.filter { $0.pathComponents.starts(with: pathComponents) }
            if affected.isEmpty {
                return make(.redundant, nil)
            }
            return make(.applicable, .deleteCrate(pathComponents: pathComponents))
        }
    }

    /// The library's current value for a field, formatted to match how a
    /// snapshot recorded it so equality checks line up.
    static func value(of field: TrackField, in track: Track) -> String? {
        switch field {
        case .title: return track.title.isEmpty ? nil : track.title
        case .artist: return track.artist.isEmpty ? nil : track.artist
        case .album: return track.album.isEmpty ? nil : track.album
        case .genre: return track.genre.isEmpty ? nil : track.genre
        case .comment: return track.comment.isEmpty ? nil : track.comment
        case .key: return track.key
        case .bpm: return track.bpm.map { String($0) }
        case .year: return track.year.map(String.init)
        }
    }

    private static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nothing" }
        return "\"\(value)\""
    }
}
