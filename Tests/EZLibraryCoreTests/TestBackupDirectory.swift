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
@testable import EZLibraryCore

/// One pre-write-snapshot directory for the whole test process.
///
/// `SeratoBackupBeforeWrite.backupDirectory` is a shared static and suites
/// run in parallel, so a suite pointing it inside its own scratch root meant
/// another suite could be mid-snapshot into that root when the first one's
/// teardown deleted it. Everyone targets this instead: it lives outside every
/// scratch root and nothing removes it during the run.
///
/// No test asserts on snapshot contents — redirecting only keeps writes out
/// of the real Application Support directory.
enum TestBackupDirectory {
    static let shared: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezlibrary-test-backups-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Point `SeratoBackupBeforeWrite` at the shared directory. Safe to call
    /// from any test, in any order — it always sets the same value.
    static func use() {
        SeratoBackupBeforeWrite.backupDirectory = shared
    }
}
