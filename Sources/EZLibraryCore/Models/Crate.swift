import Foundation

/// A single Serato crate, parsed from one `.crate` file under `Subcrates/`.
///
/// Nested crates are stored on disk as one flat file whose name encodes the
/// hierarchy with a `≫≫` (U+226B doubled) separator, e.g.
/// `ALL GENRES≫≫Disco.crate` is the "Disco" crate nested under "ALL GENRES".
/// Building the cross-crate parent/child tree from a directory of these is
/// `CrateHierarchy`'s job, not this type's — `Crate` only knows its own
/// nesting path.
public struct Crate: Identifiable, Hashable, Sendable {
    public static let nestingDelimiter = "\u{226B}\u{226B}"

    public let id: UUID

    /// This crate's own nesting path, e.g. `["ALL GENRES", "Disco"]`.
    public var pathComponents: [String]

    /// Track paths exactly as stored in the crate's `ptrk` fields — these
    /// match `Track.seratoStoredPath`, not `Track.id`, since Serato crates
    /// reference tracks by path.
    public var trackPaths: [String]

    /// The `.crate` file this was read from, or `nil` for a crate not yet
    /// written to disk.
    public var fileURL: URL?

    public var name: String { pathComponents.last ?? "" }

    public init(
        pathComponents: [String],
        trackPaths: [String] = [],
        fileURL: URL? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.pathComponents = pathComponents
        self.trackPaths = trackPaths
        self.fileURL = fileURL
    }

    /// Derives `pathComponents` from a `.crate` file's base name.
    public static func pathComponents(forCrateFileNamed baseName: String) -> [String] {
        baseName.components(separatedBy: nestingDelimiter)
    }

    /// The on-disk base file name (without extension) for `pathComponents`.
    public static func fileBaseName(forPathComponents pathComponents: [String]) -> String {
        pathComponents.joined(separator: nestingDelimiter)
    }
}
