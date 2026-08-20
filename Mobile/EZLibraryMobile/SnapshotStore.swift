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
import Observation
import EZLibrarySnapshotKit

/// Owns the loaded library and the folder it came from.
///
/// The parsing, searching, and tree-building all live in
/// `EZLibrarySnapshotKit`, where they're unit-tested and compiled for iOS by
/// CI. This is only the state machine around them.
@Observable
final class SnapshotStore {
    enum State {
        case needsFolder
        case loading
        case loaded(SnapshotLibrary)
        case failed(String)
    }

    private(set) var state: State = .needsFolder
    private(set) var folderURL: URL?

    var library: SnapshotLibrary? {
        if case let .loaded(library) = state { return library }
        return nil
    }

    /// Loads from the previously chosen folder, if there is one.
    func restore() {
        guard let url = SnapshotFolderBookmark.resolve() else {
            state = .needsFolder
            return
        }
        folderURL = url
        load(from: url)
    }

    /// Adopts a folder the user just picked.
    func use(folder url: URL) {
        do {
            try SnapshotFolderBookmark.save(url)
        } catch {
            state = .failed("Couldn't keep access to that folder: \(error.localizedDescription)")
            return
        }
        folderURL = url
        load(from: url)
    }

    func reload() {
        guard let folderURL else {
            state = .needsFolder
            return
        }
        load(from: folderURL)
    }

    func forgetFolder() {
        SnapshotFolderBookmark.forget()
        folderURL = nil
        state = .needsFolder
    }

    private func load(from url: URL) {
        state = .loading
        do {
            let library = try SnapshotFolderBookmark.withAccess(to: url) {
                try SnapshotFolder.loadNewest(in: url)
            }
            state = .loaded(library)
        } catch let error as LocalizedError {
            // These errors already say what to do about it — a snapshot from a
            // newer EZLibrary, a damaged file, an empty folder.
            state = .failed([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " "))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
