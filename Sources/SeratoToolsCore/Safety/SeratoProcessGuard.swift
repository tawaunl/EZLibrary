import AppKit

/// Detects whether Serato itself is currently running, so callers can
/// refuse or warn before mutating `database V2`/`.crate` files — writing to
/// them while Serato is open risks Serato's own next save clobbering the
/// change, or Serato reading a half-written file.
public enum SeratoProcessGuard {
    /// Matches Serato DJ Pro's confirmed bundle identifier
    /// (`com.serato.seratodj`) plus the `com.serato.` prefix generally, to
    /// also catch Serato DJ Lite and future Serato apps without needing
    /// their exact identifiers.
    private static let bundleIdentifierPrefix = "com.serato."

    public static var isSeratoRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier?.hasPrefix(bundleIdentifierPrefix) ?? false
        }
    }
}
