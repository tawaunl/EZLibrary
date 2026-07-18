import Foundation

/// A one-shot, indexed filename scan across a set of root directories —
/// built once per scan session so matching many missing tracks doesn't
/// re-walk the disk per track ("fast even on large libraries").
///
/// Deliberately does *not* scan `/` or request Full Disk Access: system and
/// other-user directories have no realistic chance of holding a DJ's audio
/// files, and scanning them only produces slow scans and scary TCC prompts.
public struct FileSystemScanner: Sendable {
    public struct Index: Sendable {
        /// Lowercased filename -> every matching absolute file URL found.
        public let byFilename: [String: [URL]]

        public func candidates(forFilename filename: String) -> [URL] {
            byFilename[filename.lowercased()] ?? []
        }
    }

    /// `~/Music`, `~/Downloads`, `~/Desktop`, and every currently-mounted
    /// volume under `/Volumes` (covers external drives, where Serato
    /// libraries commonly live). Computed, not cached, so newly-mounted
    /// volumes are picked up and it stays overridable in tests.
    public static var defaultScanRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop")
        ]
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil
        )) ?? []
        roots.append(contentsOf: volumes)
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Scans `roots` and returns a filename index. Intended to run off the
    /// main actor — this can take real time on large volumes.
    public static func scanRoots(_ roots: [URL]) -> Index {
        var byFilename: [String: [URL]] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                byFilename[url.lastPathComponent.lowercased(), default: []].append(url)
            }
        }
        return Index(byFilename: byFilename)
    }
}
