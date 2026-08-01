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

enum SeratoFeatureFlags {
    static let autoRenameFromMetadataDefaultsKey = "SeratoToolsAutoRenameFromMetadata"
    static let mainMusicFolderDefaultsKey = "YouTubeRipDestinationPath"
    static let addMusicUsesCentralCrateDefaultsKey = "AddMusicUsesCentralCrate"
    static let addMusicCentralCrateIDDefaultsKey = "AddMusicCentralCrateID"
    static let filenameFormatTemplateDefaultsKey = "SeratoToolsFilenameFormatTemplate"

    /// The default filename format template used when none has been explicitly saved.
    /// Tokens: {artist}, {title}, {album}, {year}, {bpm}, {key}, {genre}.
    static let defaultFilenameFormatTemplate = "{artist}-{title}-{album}-{year}"

    /// Returns the user's saved filename format template, or the default if none is set.
    static func filenameFormatTemplate(userDefaults: UserDefaults = .standard) -> String {
        let saved = userDefaults.string(forKey: filenameFormatTemplateDefaultsKey) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultFilenameFormatTemplate
            : saved
    }

    /// Marks that the one-time "disable auto-rename" migration has run, so it
    /// resets the preference exactly once instead of on every launch.
    private static let disabledAutoRenameMigrationKey = "SeratoToolsDidDisableAutoRenameMigration"

    static func isAutoRenameFromMetadataEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        // Defaults to off because renaming files on disk is a bigger action
        // than the tag edit that triggers it, not because it's unsafe:
        // `SeratoTrackMetadataEditor` now carries the new path into
        // `location.sqlite` as well as `database V2`, so a renamed track
        // keeps its Serato library entry, cues and crate membership.
        userDefaults.object(forKey: autoRenameFromMetadataDefaultsKey) == nil
            ? false
            : userDefaults.bool(forKey: autoRenameFromMetadataDefaultsKey)
    }

    /// One-time reset of the auto-rename preference to off. Earlier builds
    /// defaulted (and auto-persisted) this to on, back when a rename orphaned
    /// the track in Serato; this forces it off once for existing installs
    /// while leaving the toggle free to be turned back on afterwards.
    static func applyDisableAutoRenameMigrationIfNeeded(userDefaults: UserDefaults = .standard) {
        guard !userDefaults.bool(forKey: disabledAutoRenameMigrationKey) else { return }
        userDefaults.set(false, forKey: autoRenameFromMetadataDefaultsKey)
        userDefaults.set(true, forKey: disabledAutoRenameMigrationKey)
    }
}
