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

/// A cheap, deterministic hash of the library's on-disk state, used to answer
/// "has anything changed since this snapshot?" without reparsing 1.7 MB of
/// `database V2`.
///
/// Uses FNV-1a rather than a cryptographic digest on purpose: this detects
/// accidental change, not tampering, and staying on plain Foundation keeps
/// `EZLibraryCore` portable to the platforms the roadmap targets.
public enum LibraryFingerprint {
    /// Fingerprints `database V2` plus every crate file, so a change to any
    /// one of them produces a different value.
    ///
    /// Missing files contribute a stable "absent" marker rather than being
    /// skipped — deleting a crate has to change the fingerprint too.
    public static func compute(
        libraryDirectory: URL,
        fileManager: FileManager = .default
    ) -> String {
        var inputs: [String] = []

        let databaseFile = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        inputs.append(descriptor(for: databaseFile, fileManager: fileManager))

        let crateFiles = SeratoLibraryLocator.subcrateFiles(in: libraryDirectory)
            + SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory)

        // Directory enumeration order isn't guaranteed, so sort before hashing
        // or the same library fingerprints differently between runs.
        inputs.append(contentsOf: crateFiles
            .map { descriptor(for: $0.url, fileManager: fileManager) }
            .sorted())

        return hash(inputs.joined(separator: "\n"))
    }

    /// `name|size|modified-seconds`, or `name|absent` when the file is gone.
    private static func descriptor(for url: URL, fileManager: FileManager) -> String {
        let name = url.lastPathComponent
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return "\(name)|absent"
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        // Whole seconds only: sub-second resolution varies by filesystem, and
        // a fingerprint that changes when nothing did is worse than useless.
        let modified = (attributes[.modificationDate] as? Date)
            .map { Int64($0.timeIntervalSince1970) } ?? -1
        return "\(name)|\(size)|\(modified)"
    }

    /// FNV-1a (64-bit), rendered as zero-padded hex.
    public static func hash(_ string: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* prime
        }
        return String(format: "%016llx", value)
    }
}
