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

/// Renames a crate by moving its `.crate`/`.scrate` file(s) on disk.
///
/// A crate's nesting path is encoded in its file name (with the `≫≫`
/// delimiter) and/or in real subdirectories under `Subcrates`/`SmartCrates`,
/// so renaming one path segment cascades to every descendant file that
/// embeds that segment. Track membership lives inside the files as paths and
/// is untouched — only the crate's own name changes.
public enum CrateRenameService {
    public enum RenameError: Error, LocalizedError {
        case seratoIsRunning
        case emptyName
        case invalidName
        case nameCollision(String)
        case crateNotFound

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato is currently running. Quit Serato before renaming crates so it doesn't overwrite the change."
            case .emptyName:
                return "Enter a name for the crate."
            case .invalidName:
                return "A crate name can't contain \u{201C}/\u{201D} or the crate nesting separator."
            case let .nameCollision(name):
                return "A crate named \u{201C}\(name)\u{201D} already exists at that level."
            case .crateNotFound:
                return "Couldn't find the crate to rename. Reload the library and try again."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then retry. Serato rewrites its crates from memory on quit, which would revert this change."
            case .nameCollision:
                return "Choose a different name."
            case .emptyName, .invalidName, .crateNotFound:
                return nil
            }
        }
    }

    /// Renames the crate at `pathComponents` (its full nesting path) so its
    /// last segment becomes `rawNewName`, cascading to every descendant file.
    /// Returns the number of crate files moved.
    @discardableResult
    public static func rename(
        crateAtPath pathComponents: [String],
        to rawNewName: String,
        libraryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw RenameError.seratoIsRunning
        }

        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { throw RenameError.emptyName }
        guard !newName.contains(Crate.nestingDelimiter), !newName.contains("/") else {
            throw RenameError.invalidName
        }
        guard let renameIndex = pathComponents.indices.last else {
            throw RenameError.crateNotFound
        }

        let subcratesDirectory = SeratoLibraryLocator.subcratesDirectory(in: libraryDirectory)
        let smartCratesDirectory = SeratoLibraryLocator.smartCratesDirectory(in: libraryDirectory)

        let sources: [(entry: SeratoLibraryLocator.CrateFileEntry, container: URL, fileExtension: String)] =
            SeratoLibraryLocator.subcrateFiles(in: libraryDirectory)
                .map { ($0, subcratesDirectory, "crate") }
            + SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory)
                .map { ($0, smartCratesDirectory, "scrate") }

        var moves: [(from: URL, to: URL)] = []
        var matchedAnyFile = false
        for source in sources {
            let filenameComponents = Crate.pathComponents(
                forCrateFileNamed: source.entry.url.deletingPathExtension().lastPathComponent)
            let fullComponents = source.entry.directoryComponents + filenameComponents
            guard fullComponents.starts(with: pathComponents) else { continue }
            matchedAnyFile = true

            var newDirectoryComponents = source.entry.directoryComponents
            var newFilenameComponents = filenameComponents
            if renameIndex < source.entry.directoryComponents.count {
                newDirectoryComponents[renameIndex] = newName
            } else {
                newFilenameComponents[renameIndex - source.entry.directoryComponents.count] = newName
            }

            var destination = source.container
            for component in newDirectoryComponents {
                destination.appendPathComponent(component, isDirectory: true)
            }
            destination = destination
                .appendingPathComponent(Crate.fileBaseName(forPathComponents: newFilenameComponents))
                .appendingPathExtension(source.fileExtension)

            if destination.standardizedFileURL.path != source.entry.url.standardizedFileURL.path {
                moves.append((source.entry.url, destination))
            }
        }

        guard matchedAnyFile else { throw RenameError.crateNotFound }
        guard !moves.isEmpty else { return 0 }

        try assertNoCollisions(in: moves, fileManager: fileManager)

        var vacatedDirectories: Set<URL> = []
        for move in moves {
            if fileManager.fileExists(atPath: move.from.path) {
                try SeratoBackupBeforeWrite.snapshot(of: move.from)
            }
            try performMove(from: move.from, to: move.to, fileManager: fileManager)
            vacatedDirectories.insert(move.from.deletingLastPathComponent())
        }

        pruneEmptyDirectories(
            vacatedDirectories,
            notBelow: [subcratesDirectory, smartCratesDirectory],
            fileManager: fileManager)

        return moves.count
    }

    /// Fails if any destination is occupied by a crate that isn't one of the
    /// files we're moving (matched case-insensitively so a case-only rename
    /// onto its own file isn't mistaken for a clash).
    private static func assertNoCollisions(
        in moves: [(from: URL, to: URL)],
        fileManager: FileManager
    ) throws {
        let sourcePaths = Set(moves.map { $0.from.standardizedFileURL.path.lowercased() })
        for move in moves {
            let destinationPath = move.to.standardizedFileURL.path
            guard fileManager.fileExists(atPath: destinationPath) else { continue }
            if !sourcePaths.contains(destinationPath.lowercased()) {
                throw RenameError.nameCollision(move.to.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private static func performMove(from: URL, to: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: to.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A case-only rename in the same directory (e.g. "house" → "House") is
        // a no-op move on a case-insensitive volume, so route it through a
        // temporary name rather than tripping FileManager's "already exists".
        let sameParent = from.deletingLastPathComponent().standardizedFileURL.path
            == to.deletingLastPathComponent().standardizedFileURL.path
        let caseOnlyRename = from.lastPathComponent != to.lastPathComponent
            && from.lastPathComponent.lowercased() == to.lastPathComponent.lowercased()
        if sameParent && caseOnlyRename {
            let staging = from.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(to.pathExtension)
            try fileManager.moveItem(at: from, to: staging)
            try fileManager.moveItem(at: staging, to: to)
            return
        }

        try fileManager.moveItem(at: from, to: to)
    }

    /// Removes now-empty directories left behind by a directory-segment
    /// rename, walking up toward (but never removing) the container roots.
    private static func pruneEmptyDirectories(
        _ directories: Set<URL>,
        notBelow roots: [URL],
        fileManager: FileManager
    ) {
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        for directory in directories {
            var current = directory.standardizedFileURL
            while !rootPaths.contains(current.path) {
                let contents = (try? fileManager.contentsOfDirectory(atPath: current.path)) ?? ["keep"]
                guard contents.isEmpty else { break }
                try? fileManager.removeItem(at: current)
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }
    }
}
