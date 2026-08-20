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

/// Keeps the Homebrew-managed runtime dependencies (yt-dlp, ffmpeg,
/// chromaprint) current so the app doesn't rely on stale copies. yt-dlp in
/// particular breaks as YouTube changes; ffmpeg and chromaprint are refreshed
/// for parity.
///
/// Everything here is best-effort and safe to call from a background task: it
/// never throws, does nothing when Homebrew isn't installed, and is throttled
/// so it runs at most once per day. All subprocesses run with an explicit,
/// non-login environment so the user's shell profile is never sourced (some
/// profiles invoke `java`/`jenv`, which pops macOS's "No Java runtime present"
/// dialog).
public enum HomebrewMaintenanceService {
    private static let lastRefreshDefaultsKey = "SeratoToolsLastHomebrewRefresh"

    /// Formulae the app depends on, kept in sync with the installer bootstrap
    /// (`Scripts/install-dependencies.sh`).
    private static let managedFormulae = ["yt-dlp", "ffmpeg", "chromaprint"]

    /// Refreshes installed dependency formulae to their latest versions at most
    /// once per day. Returns whether a refresh was attempted.
    @discardableResult
    public static func refreshIfDue(
        force: Bool = false,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if !force,
           let last = userDefaults.object(forKey: lastRefreshDefaultsKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return false
        }

        guard let brewPath = resolveBrewPath() else {
            // No Homebrew: nothing to maintain here. The self-updating managed
            // yt-dlp copy still covers YouTube downloads as a fallback.
            return false
        }

        // Refresh Homebrew's formula index once so upgrades see new versions.
        _ = runBrew(brewPath, ["update", "--quiet"])

        for formula in managedFormulae where isFormulaInstalled(brewPath, formula) {
            _ = runBrew(brewPath, ["upgrade", "--quiet", formula])
        }

        // Stamp only after the work completes so an interrupted or failed run
        // doesn't burn the daily window and can retry on the next launch.
        userDefaults.set(Date(), forKey: lastRefreshDefaultsKey)

        return true
    }

    public static func resolveBrewPath(fileManager: FileManager = .default) -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// The managed formulae that Homebrew reports as having a newer version
    /// available. Empty when Homebrew isn't installed or everything is current.
    public static func outdatedManagedFormulae() -> [String] {
        guard let brewPath = resolveBrewPath() else { return [] }
        guard let output = runBrewCapturingOutput(brewPath, ["outdated", "--formula", "--quiet"]) else {
            return []
        }
        let outdated = Set(
            output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        return managedFormulae.filter { outdated.contains($0) }
    }

    private static func isFormulaInstalled(_ brewPath: String, _ formula: String) -> Bool {
        runBrew(brewPath, ["list", "--formula", formula]) == 0
    }

    /// Runs a brew command with a clean, non-login environment and returns its
    /// exit code (or nil if it couldn't be launched). Output is discarded.
    @discardableResult
    private static func runBrew(_ brewPath: String, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        process.environment = cleanEnvironment(brewPath: brewPath)
        // Discard to /dev/null rather than an undrained Pipe(): `brew update`
        // and `brew upgrade` emit more than the OS pipe buffer holds, and a
        // full, unread pipe blocks brew and deadlocks waitUntilExit().
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a brew command with a clean, non-login environment and returns its
    /// standard output (or nil if it couldn't be launched).
    private static func runBrewCapturingOutput(_ brewPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        process.environment = cleanEnvironment(brewPath: brewPath)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Discard stderr to /dev/null; an undrained stderr Pipe() would
        // deadlock waitUntilExit() if brew wrote past the buffer limit.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func cleanEnvironment(brewPath: String) -> [String: String] {
        let brewBinDirectory = (brewPath as NSString).deletingLastPathComponent
        return [
            "PATH": "\(brewBinDirectory):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_ANALYTICS": "1"
        ]
    }
}
