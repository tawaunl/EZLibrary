import Foundation

/// Writes file contents via a temp-file-then-rename, so a crash or power
/// loss mid-write can never leave a truncated `database V2`/`.crate` file on
/// disk.
public enum AtomicFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
