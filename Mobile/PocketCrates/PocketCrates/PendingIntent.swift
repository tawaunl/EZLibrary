import Foundation
import EZLibrarySnapshotKit

// MARK: - Data model

struct PendingIntent: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let snapshotID: UUID
    let operation: IntentOperation
}

enum IntentOperation: Codable, Sendable {
    case editTrackField(storedPath: String, field: TrackField, oldValue: String?, newValue: String)
    case renameCrate(pathComponents: [String], newName: String)
    case deleteCrate(pathComponents: [String])
    case createCrate(name: String, parentPathComponents: [String])

    var summary: String {
        switch self {
        case let .editTrackField(path, field, _, new):
            let file = (path as NSString).lastPathComponent
            return "Edit \(field.displayName) → \"\(new)\" (\(file))"
        case let .renameCrate(c, new):
            return "Rename \"\(c.last ?? "")\" → \"\(new)\""
        case let .deleteCrate(c):
            return "Delete crate \"\(c.last ?? "")\""
        case let .createCrate(name, parent):
            return parent.isEmpty
                ? "New crate \"\(name)\""
                : "New crate \"\(name)\" in \"\(parent.last ?? "")\""
        }
    }
}

// MARK: - IntentOperation Codable (explicit, stable format for Mac to consume)

extension IntentOperation {
    private enum TypeKey: String, Codable {
        case editTrackField, renameCrate, deleteCrate, createCrate
    }
    private enum CK: String, CodingKey {
        case type, storedPath, field, oldValue, newValue
        case pathComponents, newName, name, parentPathComponents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CK.self)
        switch try c.decode(TypeKey.self, forKey: .type) {
        case .editTrackField:
            self = .editTrackField(
                storedPath: try c.decode(String.self, forKey: .storedPath),
                field:      try c.decode(TrackField.self, forKey: .field),
                oldValue:   try c.decodeIfPresent(String.self, forKey: .oldValue),
                newValue:   try c.decode(String.self, forKey: .newValue)
            )
        case .renameCrate:
            self = .renameCrate(
                pathComponents: try c.decode([String].self, forKey: .pathComponents),
                newName:        try c.decode(String.self, forKey: .newName)
            )
        case .deleteCrate:
            self = .deleteCrate(pathComponents: try c.decode([String].self, forKey: .pathComponents))
        case .createCrate:
            self = .createCrate(
                name:                 try c.decode(String.self, forKey: .name),
                parentPathComponents: try c.decode([String].self, forKey: .parentPathComponents)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case let .editTrackField(path, field, old, new):
            try c.encode(TypeKey.editTrackField, forKey: .type)
            try c.encode(path,  forKey: .storedPath)
            try c.encode(field, forKey: .field)
            try c.encodeIfPresent(old, forKey: .oldValue)
            try c.encode(new,   forKey: .newValue)
        case let .renameCrate(components, newName):
            try c.encode(TypeKey.renameCrate,  forKey: .type)
            try c.encode(components,           forKey: .pathComponents)
            try c.encode(newName,              forKey: .newName)
        case let .deleteCrate(components):
            try c.encode(TypeKey.deleteCrate, forKey: .type)
            try c.encode(components,          forKey: .pathComponents)
        case let .createCrate(name, parent):
            try c.encode(TypeKey.createCrate, forKey: .type)
            try c.encode(name,   forKey: .name)
            try c.encode(parent, forKey: .parentPathComponents)
        }
    }
}

// MARK: - Applying intents to a snapshot

extension LibrarySnapshot {
    /// Returns a new snapshot with all intents applied in order.
    func applying(_ intents: [PendingIntent]) -> LibrarySnapshot {
        guard !intents.isEmpty else { return self }

        var trackMap = Dictionary(uniqueKeysWithValues: tracks.map { ($0.storedPath, $0) })
        var crates = self.crates

        for intent in intents {
            switch intent.operation {

            case let .editTrackField(path, field, _, newValue):
                if var t = trackMap[path] {
                    t.apply(field: field, value: newValue)
                    trackMap[path] = t
                }

            case let .renameCrate(pathComponents, newName):
                // Rename this crate and every sub-crate sharing the path prefix.
                crates = crates.map { crate in
                    guard crate.pathComponents.starts(with: pathComponents) else { return crate }
                    let newPath = Array(pathComponents.dropLast()) + [newName]
                        + Array(crate.pathComponents.dropFirst(pathComponents.count))
                    return SnapshotCrate(pathComponents: newPath, trackPaths: crate.trackPaths)
                }

            case let .deleteCrate(pathComponents):
                crates = crates.filter { !$0.pathComponents.starts(with: pathComponents) }

            case let .createCrate(name, parentPathComponents):
                let newPath = parentPathComponents + [name]
                if !crates.contains(where: { $0.pathComponents == newPath }) {
                    crates.append(SnapshotCrate(pathComponents: newPath, trackPaths: []))
                }
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
    mutating func apply(field: TrackField, value: String) {
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
