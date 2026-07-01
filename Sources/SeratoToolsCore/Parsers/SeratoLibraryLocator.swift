import Foundation

/// Locates the on-disk layout of a user's Serato library (`_Serato_` folder)
/// and resolves the path convention Serato uses inside `database V2`/`.crate`
/// files.
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

    public static func subcrateFiles(in libraryDirectory: URL = defaultLibraryDirectory) -> [URL] {
        let directory = subcratesDirectory(in: libraryDirectory)
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (files ?? []).filter { $0.pathExtension == "crate" }
    }

    /// The directory that `pfil`/`ptrk` paths stored inside this library are
    /// relative to.
    ///
    /// Serato stores paths without a leading separator: for a library on the
    /// boot/home volume, paths are relative to the filesystem root ("/"); for
    /// a library on an external volume, paths are relative to that volume's
    /// mount point (the parent directory of `_Serato_`).
    public static func rootDirectory(
        for libraryDirectory: URL = defaultLibraryDirectory,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let volumeRoot = libraryDirectory.deletingLastPathComponent()
        let resolvedVolumeRoot = volumeRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        if resolvedVolumeRoot.path.hasPrefix(resolvedHome.path) {
            return URL(fileURLWithPath: "/")
        }
        return volumeRoot
    }

    /// Resolves a raw Serato-stored path (as found in `pfil`/`ptrk`) to an
    /// absolute file URL, given the library's root directory.
    public static func resolve(seratoStoredPath: String, rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(seratoStoredPath)
    }

    /// Converts an absolute file URL back into the Serato-stored path
    /// convention (relative to `rootDirectory`), for writing.
    public static func seratoStoredPath(for fileURL: URL, rootDirectory: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        var filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            filePath.removeFirst(rootPath.count)
        }
        while filePath.hasPrefix("/") {
            filePath.removeFirst()
        }
        return filePath
    }
}
