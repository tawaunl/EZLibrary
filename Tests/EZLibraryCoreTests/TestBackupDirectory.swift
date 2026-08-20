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
        TestSeratoEnvironment.isolateApplicationSupport()
        TestSeratoEnvironment.assumeSeratoClosedUnlessSet()
    }
}

/// Keeps tests away from the developer's real Serato installation.
enum TestSeratoEnvironment {
    /// An empty stand-in for `~/Library/Application Support`.
    ///
    /// `SeratoLocationDatabase.activeDatabases` looks up Serato's live
    /// databases through `master.sqlite` there. Left unset, any test that
    /// renames a track would find the real one and write to the actual
    /// library — including bumping its revision counter.
    static let applicationSupport: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ezlibrary-test-appsupport-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func isolateApplicationSupport() {
        SeratoLocationDatabase.applicationSupportDirectoryOverride = applicationSupport
        LibraryChangeJournal.applicationSupportDirectoryOverride = applicationSupport
    }

    /// Force the "Serato is closed" answer for the whole test process.
    ///
    /// `SeratoProcessGuard` otherwise asks `NSWorkspace`, so every write-path
    /// test would fail on a machine that simply has Serato open. Tests that
    /// exercise the refusal set the override to `true` themselves and must
    /// restore it with `pretendSeratoIsClosed()` rather than `nil` — clearing
    /// it re-exposes the real check to whatever else is running in parallel.
    static func pretendSeratoIsClosed() {
        SeratoProcessGuard.isRunningOverride = false
    }

    /// Run `body` with Serato reported as running, scoped to this task only.
    ///
    /// Prefer this over assigning `SeratoProcessGuard.isRunningOverride`:
    /// that is process-wide, and tests run in parallel, so setting it made
    /// every concurrently running write test fail at random.
    static func withSeratoRunning<T>(_ body: () throws -> T) rethrows -> T {
        try SeratoProcessGuard.$isRunningForCurrentTask.withValue(true, operation: body)
    }

    static func withSeratoRunning<T>(_ body: () async throws -> T) async rethrows -> T {
        try await SeratoProcessGuard.$isRunningForCurrentTask.withValue(true, operation: body)
    }

    /// Establish the "Serato is closed" default without stomping a value a
    /// test set on purpose.
    ///
    /// `use()` runs from tests in every suite, and suites run in parallel, so
    /// setting the override unconditionally there raced with the tests that
    /// set it to `true` to exercise the refusal — the guard would silently not
    /// fire and those tests failed at random.
    static func assumeSeratoClosedUnlessSet() {
        if SeratoProcessGuard.isRunningOverride == nil {
            SeratoProcessGuard.isRunningOverride = false
        }
    }
}
