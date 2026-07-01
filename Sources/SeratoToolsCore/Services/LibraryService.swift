import Foundation

/// High-level entry point for loading and managing a Serato library.
@MainActor
public final class LibraryService: ObservableObject {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var crates: [Crate] = []

    private let libraryDirectory: URL

    public init(libraryDirectory: URL = SeratoLibraryLocator.defaultLibraryDirectory) {
        self.libraryDirectory = libraryDirectory
    }

    public func reload() throws {
        let databaseFile = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        tracks = try SeratoDatabaseParser.parseTracks(at: databaseFile)
    }
}
