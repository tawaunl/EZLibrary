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

/// Publishes a staged export onto a stick so an interruption can always be undone.
///
/// Everything new is written under `.cdjexport-publication/stage/` first. Once
/// it verifies, a journal listing the paths about to change is written, then
/// each staged file is moved into place (renames on one volume are cheap) with
/// anything it replaces moved to `backup/`. If any step fails, or the next run
/// finds a journal left by a crash, the moves are undone from what is on disk.
/// The databases are placed last, so a stick never points at files that aren't there.
struct CDJExportPublication {
    static let directoryName = ".cdjexport-publication"

    struct Journal: Codable, Equatable {
        /// Volume-relative paths (no leading slash) that will be written.
        var placements: [String]
        /// Volume-relative paths that will be deleted.
        var removals: [String]
    }

    let volume: URL
    private let fileManager = FileManager.default

    init(volume: URL) {
        self.volume = volume
    }

    var directory: URL { volume.appendingPathComponent(Self.directoryName) }
    var stage: URL { directory.appendingPathComponent("stage") }
    private var backup: URL { directory.appendingPathComponent("backup") }
    private var journalURL: URL { directory.appendingPathComponent("journal.json") }

    func stagedURL(_ relativePath: String) -> URL { stage.appendingPathComponent(relativePath) }

    /// Removes anything left by an earlier run and creates an empty stage.
    func prepare() throws {
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
    }

    /// If a previous run died while publishing, puts the stick back as it was.
    /// Returns whether there was anything to undo.
    @discardableResult
    func recoverInterruptedPublication() throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        if let data = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(Journal.self, from: data) {
            try rollback(journal)
            try? fileManager.removeItem(at: directory)
            return true
        }
        // No journal means publishing never started; the stage is just litter.
        try? fileManager.removeItem(at: directory)
        return false
    }

    /// Moves staged files into place and removes `removals`. On any failure the
    /// stick is restored and the error rethrown.
    func commit(_ journal: Journal) throws {
        try AtomicFileWriter.write(try JSONEncoder().encode(journal), to: journalURL)
        do {
            for relative in journal.placements {
                let destination = volume.appendingPathComponent(relative)
                try backUpIfPresent(relative)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: stagedURL(relative), to: destination)
            }
            for relative in journal.removals {
                try backUpIfPresent(relative)
            }
        } catch {
            try? rollback(journal)
            throw error
        }
    }

    /// Undoes `commit` after a later check fails.
    func abandon(_ journal: Journal) throws {
        try rollback(journal)
    }

    /// Discards the stage, the backups and the journal after a successful publish.
    func finish() {
        try? fileManager.removeItem(at: directory)
    }

    /// Removes folders emptied by the removals, up to (not including) `stopAt`.
    func pruneEmptyFolders(after journal: Journal, stopAt: Set<String>) {
        for relative in journal.removals {
            var folder = volume.appendingPathComponent(relative).deletingLastPathComponent()
            while folder.path.count > volume.path.count {
                let name = folder.lastPathComponent
                if stopAt.contains(name) { break }
                let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["-"]
                guard contents.isEmpty else { break }
                try? fileManager.removeItem(at: folder)
                folder.deleteLastPathComponent()
            }
        }
    }

    // MARK: - Helpers

    private func backUpIfPresent(_ relative: String) throws {
        let current = volume.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: current.path) else { return }
        let saved = backup.appendingPathComponent(relative)
        try fileManager.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: current, to: saved)
    }

    /// Restores the stick from what is on disk, so it is safe to run more than once
    /// and after a crash at any point in `commit`.
    private func rollback(_ journal: Journal) throws {
        for relative in journal.placements.reversed() {
            let destination = volume.appendingPathComponent(relative)
            let saved = backup.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: saved.path) {
                // The original was moved aside: put it back over whatever replaced it.
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: saved, to: destination)
            } else if fileManager.fileExists(atPath: destination.path),
                      !fileManager.fileExists(atPath: stagedURL(relative).path) {
                // A new file already moved out of the stage, with nothing to restore.
                try fileManager.removeItem(at: destination)
            }
        }
        for relative in journal.removals {
            let destination = volume.appendingPathComponent(relative)
            let saved = backup.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: saved.path), !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: saved, to: destination)
            }
        }
    }
}
