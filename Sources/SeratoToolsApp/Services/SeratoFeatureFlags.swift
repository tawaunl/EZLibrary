import Foundation

enum SeratoFeatureFlags {
    static let autoRenameFromMetadataDefaultsKey = "SeratoToolsAutoRenameFromMetadata"
    static let mainMusicFolderDefaultsKey = "YouTubeRipDestinationPath"
    static let addMusicUsesCentralCrateDefaultsKey = "AddMusicUsesCentralCrate"
    static let addMusicCentralCrateIDDefaultsKey = "AddMusicCentralCrateID"

    /// Marks that the one-time "disable auto-rename" migration has run, so it
    /// resets the preference exactly once instead of on every launch.
    private static let disabledAutoRenameMigrationKey = "SeratoToolsDidDisableAutoRenameMigration"

    static func isAutoRenameFromMetadataEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        // Defaults to off: renaming a file Serato has already analyzed orphans
        // the original library entry and makes Serato re-import the renamed
        // file as a new track. Tag edits should update metadata in place.
        userDefaults.object(forKey: autoRenameFromMetadataDefaultsKey) == nil
            ? false
            : userDefaults.bool(forKey: autoRenameFromMetadataDefaultsKey)
    }

    /// One-time reset of the auto-rename preference to off. Earlier builds
    /// defaulted (and auto-persisted) this to on, which orphaned tracks in
    /// Serato; this forces it off once for existing installs while leaving the
    /// toggle free to be turned back on afterwards.
    static func applyDisableAutoRenameMigrationIfNeeded(userDefaults: UserDefaults = .standard) {
        guard !userDefaults.bool(forKey: disabledAutoRenameMigrationKey) else { return }
        userDefaults.set(false, forKey: autoRenameFromMetadataDefaultsKey)
        userDefaults.set(true, forKey: disabledAutoRenameMigrationKey)
    }
}
