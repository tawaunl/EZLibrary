import Foundation

/// High-level entry point for loading and managing a Serato library.
@MainActor
public final class LibraryService: ObservableObject {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var crates: [Crate] = []
    @Published public private(set) var smartCrates: [Crate] = []
    @Published public private(set) var reloadErrorMessage: String?

    @Published public private(set) var libraryDirectory: URL

    public init(libraryDirectory: URL = SeratoLibraryLocator.defaultLibraryDirectory) {
        self.libraryDirectory = libraryDirectory
    }

    public var databaseFile: URL {
        SeratoLibraryLocator.databaseFile(in: libraryDirectory)
    }

    public var subcratesDirectory: URL {
        SeratoLibraryLocator.subcratesDirectory(in: libraryDirectory)
    }

    public func reload() throws {
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
