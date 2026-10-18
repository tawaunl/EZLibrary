// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Darwin
import Foundation

/// Keeps two exports from publishing to the same stick at once.
///
/// Two layers: a process-wide set of stick paths (so two exports inside this
/// app can't overlap, whatever the file system supports) and an advisory
/// `flock` on a file at the top of the stick (so a second copy of the app or
/// the command-line tool is held off too). Some FAT drivers refuse `flock`;
/// the in-process layer still applies then.
final class CDJExportLock {
    static let fileName = ".cdjexport-write.lock"

    private static let registry = NSLock()
    nonisolated(unsafe) private static var held = Set<String>()

    private let key: String
    private let lockURL: URL
    private var descriptor: Int32 = -1

    /// Throws `CDJExportError.exportInProgress` when the stick is already being written to.
    init(volume: URL) throws {
        key = volume.standardizedFileURL.resolvingSymlinksInPath().path
        lockURL = volume.appendingPathComponent(Self.fileName)

        Self.registry.lock()
        let inserted = Self.held.insert(key).inserted
        Self.registry.unlock()
        guard inserted else { throw CDJExportError.exportInProgress }

        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }  // read-only or odd file system: the in-process layer is all we have
        if flock(fd, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK {
            close(fd)
            release()
            throw CDJExportError.exportInProgress
        }
        descriptor = fd
    }

    private func release() {
        Self.registry.lock()
        Self.held.remove(key)
        Self.registry.unlock()
    }

    deinit {
        if descriptor >= 0 {
            // Remove the file while still holding the lock, so nobody locks a file that's about to vanish.
            unlink(lockURL.path)
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        release()
    }
}
