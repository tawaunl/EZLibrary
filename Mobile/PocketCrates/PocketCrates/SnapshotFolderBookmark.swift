import Foundation

/// Remembers the folder the user picked, so the app doesn't ask again on
/// every launch.
///
/// A URL from the document picker grants access to a folder outside the app's
/// sandbox, but only for as long as the app keeps it. A *bookmark* makes that
/// grant survive relaunches — which is the whole reason this app needs no
/// iCloud entitlement: the user hands it one folder, once.
enum SnapshotFolderBookmark {
    private static let defaultsKey = "HMVH3CU559.PocketCrates.snapshotFolderBookmark"

    static func save(_ url: URL) throws {
        // Access has to be open while the bookmark is created, or the data
        // records a folder the app can't actually reach later.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Resolves the saved folder, or `nil` when none was ever chosen.
    ///
    /// Re-saves the bookmark when the system reports it stale — iCloud moves
    /// files around, and a stale bookmark still resolves once but won't keep
    /// working unless it's refreshed.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // The folder is gone or the grant was revoked. Drop it rather than
            // failing the same way on every launch.
            forget()
            return nil
        }

        if isStale {
            try? save(url)
        }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Runs `body` with access open to a security-scoped folder.
    ///
    /// Every read of the snapshot has to be wrapped like this; outside the
    /// scope the file simply isn't readable, which surfaces as a confusing
    /// "no such file" rather than a permissions error.
    static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
