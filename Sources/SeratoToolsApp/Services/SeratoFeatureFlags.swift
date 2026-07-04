import Foundation

enum SeratoFeatureFlags {
    static let autoRenameFromMetadataDefaultsKey = "SeratoToolsAutoRenameFromMetadata"

    static func isAutoRenameFromMetadataEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: autoRenameFromMetadataDefaultsKey) == nil
            ? true
            : userDefaults.bool(forKey: autoRenameFromMetadataDefaultsKey)
    }
}
