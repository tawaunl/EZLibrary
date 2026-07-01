import Foundation

/// Locates the on-disk layout of a user's Serato library (`_Serato_` folder).
public enum SeratoLibraryLocator {
    /// Default `_Serato_` directory under `~/Music`.
    public static var defaultLibraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music")
            .appendingPathComponent("_Serato_")
    }

    public static func databaseFile(in libraryDirectory: URL = defaultLibraryDirectory) -> URL {
        libraryDirectory.appendingPathComponent("database V2")
    }

    public static func subcratesDirectory(in libraryDirectory: URL = defaultLibraryDirectory) -> URL {
        libraryDirectory.appendingPathComponent("Subcrates")
    }
}
