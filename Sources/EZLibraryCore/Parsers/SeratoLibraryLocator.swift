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
    public struct CrateFileEntry: Sendable {
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
    /// 1) `EZLIBRARY_LIBRARY_DIR` (or legacy `SERATOTOOLS_LIBRARY_DIR`) environment variable
    /// 2) `UserDefaults` override (`libraryDirectoryDefaultsKey`)
    /// 3) largest valid `database V2` among default + mounted volumes
    /// 4) fallback to default path
    public static func discoverLibraryDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["EZLIBRARY_LIBRARY_DIR"] ?? environment["SERATOTOOLS_LIBRARY_DIR"], !override.isEmpty {
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
    ///
    /// Runs once per track on library load, so it is written to avoid
    /// per-track allocations: the candidates are compared as plain paths
    /// rather than by standardizing both URLs, which was by far the most
    /// expensive step of parsing a library kept on an external volume.
    /// Standardizing only ever collapsed two candidates that name the same
    /// file, and those resolve identically here anyway.
    public static func resolve(
        seratoStoredPath: String,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let primary = rootDirectory.appendingPathComponent(seratoStoredPath)

        // Boot-volume libraries resolve against "/", so the absolute fallback
        // is the same URL and the disk check can't change the result — and a
        // stat() per track froze the UI for the whole parse on big libraries.
        guard rootDirectory.path != "/" else { return primary }

        let fallback = filesystemRoot.appendingPathComponent(seratoStoredPath)
        let primaryPath = primary.path
        let fallbackPath = fallback.path
        guard primaryPath != fallbackPath else { return primary }

        if fileManager.fileExists(atPath: primaryPath) { return primary }
        if fileManager.fileExists(atPath: fallbackPath) { return fallback }
        return primary
    }

    private static let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)

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
