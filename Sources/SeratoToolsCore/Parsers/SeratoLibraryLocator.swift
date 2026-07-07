import Foundation

/// Locates the on-disk layout of a user's Serato library (`_Serato_` folder)
/// and resolves the path convention Serato uses inside `database V2`/`.crate`
/// files.
public enum SeratoLibraryLocator {
    /// Optional persistent override key for the app to read from
    /// `UserDefaults.standard` when no environment override is provided.
    public static let libraryDirectoryDefaultsKey = "SeratoToolsLibraryDirectory"

    /// A crate (or smart crate) file found on disk, along with the
    /// directory path it was nested under relative to its container
    /// (`Subcrates/` or `SmartCrates/`). Serato nests crates two ways: via
    /// an actual subdirectory (e.g. `Subcrates/Serato Stems/Stems.crate`)
    /// or via a `≫≫`-delimited filename (e.g.
    /// `SmartCrates/ALL GENRES≫≫Disco.scrate`) — both were confirmed
    /// against a real library. `directoryComponents` only captures the
    /// first kind; combine with `Crate.pathComponents(forCrateFileNamed:)`
    /// for the second.
    public struct CrateFileEntry {
        public let url: URL
        public let directoryComponents: [String]
    }

    /// Default `_Serato_` directory under `~/Music`.
    public static var defaultLibraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music")
            .appendingPathComponent("_Serato_")
    }

    /// Resolves the best available `_Serato_` location in this order:
    /// 1) `SERATOTOOLS_LIBRARY_DIR` environment variable
    /// 2) `UserDefaults` override (`libraryDirectoryDefaultsKey`)
    /// 3) largest valid `database V2` among default + mounted volumes
    /// 4) fallback to default path
    public static func discoverLibraryDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["SERATOTOOLS_LIBRARY_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if hasDatabase(in: url, fileManager: fileManager) {
                return url
            }
        }

        if let override = userDefaults.string(forKey: libraryDirectoryDefaultsKey), !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if hasDatabase(in: url, fileManager: fileManager) {
                return url
            }
        }

        let preferred = defaultLibraryDirectory
        let autoCandidates = [preferred] + externalLibraryDirectories(fileManager: fileManager)
        if let best = autoCandidates
            .compactMap({ url -> (url: URL, size: Int64)? in
                guard let size = databaseFileSize(in: url, fileManager: fileManager) else { return nil }
                return (url, size)
            })
            .max(by: { $0.size < $1.size })?.url {
            return best
        }

        return preferred
    }

    private static func hasDatabase(in libraryDirectory: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: databaseFile(in: libraryDirectory).path)
    }

    private static func externalLibraryDirectories(fileManager: FileManager) -> [URL] {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumeNames = try? fileManager.contentsOfDirectory(atPath: volumesURL.path) else {
            return []
        }

        var candidates: [URL] = []
        for name in volumeNames.sorted() {
            let candidate = volumesURL
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("_Serato_", isDirectory: true)
            if hasDatabase(in: candidate, fileManager: fileManager) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private static func databaseFileSize(in libraryDirectory: URL, fileManager: FileManager) -> Int64? {
        let databaseURL = databaseFile(in: libraryDirectory)
        guard let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path),
              let number = attributes[.size] as? NSNumber else {
            return nil
        }
        return number.int64Value
    }

    public static func databaseFile(in libraryDirectory: URL = defaultLibraryDirectory) -> URL {
        libraryDirectory.appendingPathComponent("database V2")
    }

    public static func subcratesDirectory(in libraryDirectory: URL = defaultLibraryDirectory) -> URL {
        libraryDirectory.appendingPathComponent("Subcrates")
    }

    public static func smartCratesDirectory(in libraryDirectory: URL = defaultLibraryDirectory) -> URL {
        // Confirmed against a real library: the on-disk folder name has no
        // space ("SmartCrates"), unlike the unverified "Smart Crates"
        // constant some other Serato format implementations use.
        libraryDirectory.appendingPathComponent("SmartCrates")
    }

    public static func subcrateFiles(in libraryDirectory: URL = defaultLibraryDirectory) -> [CrateFileEntry] {
        crateFileEntries(in: subcratesDirectory(in: libraryDirectory), extension: "crate")
    }

    public static func smartCrateFiles(in libraryDirectory: URL = defaultLibraryDirectory) -> [CrateFileEntry] {
        crateFileEntries(in: smartCratesDirectory(in: libraryDirectory), extension: "scrate")
    }

    /// Recursively finds files with `extension` under `directory`, since
    /// Serato allows nesting crates in real subdirectories in addition to
    /// its `≫≫`-delimited filename convention.
    private static func crateFileEntries(in directory: URL, extension fileExtension: String) -> [CrateFileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Resolve symlinks on both sides before comparing path components:
        // the enumerator's URLs and a separately-standardized `directory`
        // can disagree (e.g. `/var` vs. its real `/private/var` target for
        // temp directories), which silently corrupts a plain
        // `suffix(from:)` component count.
        let baseComponents = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        var entries: [CrateFileEntry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == fileExtension else { continue }
            var directoryComponents = url
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            if directoryComponents.starts(with: baseComponents) {
                directoryComponents.removeFirst(baseComponents.count)
            } else {
                directoryComponents = []
            }
            entries.append(CrateFileEntry(url: url, directoryComponents: directoryComponents))
        }
        return entries
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
    ///
    /// Some libraries contain mixed conventions where a stored path behaves
    /// like filesystem-root-relative (`Users/...`) even when the active
    /// profile root is an external volume. In that case prefer whichever
    /// candidate exists on disk.
    public static func resolve(
        seratoStoredPath: String,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let candidates = resolvedPathCandidates(
            seratoStoredPath: seratoStoredPath,
            rootDirectory: rootDirectory
        )

        if let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existing
        }

        return candidates[0]
    }

    private static func resolvedPathCandidates(seratoStoredPath: String, rootDirectory: URL) -> [URL] {
        let primary = rootDirectory.appendingPathComponent(seratoStoredPath)
        let absoluteRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let absoluteFallback = absoluteRoot.appendingPathComponent(seratoStoredPath)

        var seen = Set<String>()
        var output: [URL] = []
        for candidate in [primary, absoluteFallback] {
            let key = candidate.standardizedFileURL.path
            if seen.insert(key).inserted {
                output.append(candidate)
            }
        }
        return output
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
