import Foundation

/// High-level entry point for loading and managing a Serato library.
@MainActor
public final class LibraryService: ObservableObject {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var crates: [Crate] = []
    @Published public private(set) var smartCrates: [Crate] = []
    @Published public private(set) var reloadErrorMessage: String?

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

    public func reload() throws {
        defer {
            refreshDerivedTrackStats()
            tracksInCratesCount = Set(crates.lazy.flatMap(\.trackPaths)).count
        }

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        do {
            tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
            crates = Self.loadCrates(from: SeratoLibraryLocator.subcrateFiles(in: libraryDirectory))
            smartCrates = Self.loadCrates(from: SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory))
            reloadErrorMessage = nil
        } catch {
            tracks = []
            crates = []
            smartCrates = []
            reloadErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func reloadTracksOnly() throws {
        defer { refreshDerivedTrackStats() }

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory)
        do {
            tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile, rootDirectory: rootDirectory)
            reloadErrorMessage = nil
        } catch {
            tracks = []
            reloadErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func refreshDerivedTrackStats() {
        trackGenres = Array(Set(tracks.map(\.genre).filter { !$0.isEmpty })).sorted()
        totalArtistCount = Set(tracks.map(\.artist).filter { !$0.isEmpty }).count
    }

    public func setLibraryDirectory(_ newDirectory: URL) {
        libraryDirectory = newDirectory
    }

    /// Parses each crate file and normalizes its `pathComponents` to include
    /// any real-subdirectory nesting on top of the `≫≫`-delimited filename
    /// nesting `SeratoCrateParser` already handles, so both nesting
    /// mechanisms produce one consistent flat path for `CrateHierarchy`.
    private static func loadCrates(from entries: [SeratoLibraryLocator.CrateFileEntry]) -> [Crate] {
        entries.compactMap { entry in
            guard var crate = try? SeratoCrateParser.parseCrate(at: entry.url) else { return nil }
            crate.pathComponents = entry.directoryComponents + crate.pathComponents
            return crate
        }
    }
}
