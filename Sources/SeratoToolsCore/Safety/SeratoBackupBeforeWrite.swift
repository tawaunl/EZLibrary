import Foundation

/// Copies a Serato file into a timestamped shadow location before any
/// mutation, and prunes old shadow copies. This is a safety net for our own
/// writes, distinct from (and a precursor to) the user-facing Backup
/// feature, which builds on the same copy/retention primitives here.
public enum SeratoBackupBeforeWrite {
    /// Number of shadow copies to keep per source file name.
    ///
    /// `nonisolated(unsafe)`: intentionally a mutable knob (tests override
    /// `backupDirectory`/`retentionCount`); this type has no concurrent
    /// writers in practice.
    public nonisolated(unsafe) static var retentionCount = 20

    public nonisolated(unsafe) static var backupDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeratoTools")
            .appendingPathComponent("Backups")
            .appendingPathComponent("pre-write")
    }()

    @discardableResult
    public static func snapshot(of fileURL: URL, timestamp: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stampedName = "\(formatter.string(from: timestamp))-\(fileURL.lastPathComponent)"
            .replacingOccurrences(of: ":", with: "-")
        let destination = backupDirectory.appendingPathComponent(stampedName)

        try FileManager.default.copyItem(at: fileURL, to: destination)
        try pruneOldSnapshots(forSourceNamed: fileURL.lastPathComponent)
        return destination
    }

    private static func pruneOldSnapshots(forSourceNamed sourceName: String) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let matching = entries
            .filter { $0.lastPathComponent.hasSuffix("-\(sourceName)") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        for stale in matching.dropFirst(retentionCount) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
