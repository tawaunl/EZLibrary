import Foundation

/// Single source of truth for the external command-line tools EZLibrary
/// depends on. The app deliberately ships **without** packaged copies of
/// `yt-dlp`, `ffmpeg`/`ffprobe`, or `fpcalc`; they are installed and kept
/// current through Homebrew on the user's machine so they never go stale. This
/// service reports what's missing or outdated and can install/upgrade
/// everything in a single step.
public enum RuntimeDependencyService {
    /// Description of one required command-line tool.
    public struct Tool: Sendable, Identifiable {
        /// The command name (also the `id`).
        public let id: String
        /// Human-facing label.
        public let displayName: String
        /// Homebrew formula that provides the command.
        public let formula: String
        /// Whether the command currently resolves on the machine.
        public let isInstalled: Bool
        /// Whether Homebrew reports a newer version is available.
        public let isOutdated: Bool

        public init(
            id: String,
            displayName: String,
            formula: String,
            isInstalled: Bool,
            isOutdated: Bool
        ) {
            self.id = id
            self.displayName = displayName
            self.formula = formula
            self.isInstalled = isInstalled
            self.isOutdated = isOutdated
        }
    }

    /// Snapshot of runtime-dependency readiness taken at a point in time.
    public struct Report: Sendable {
        public let homebrewInstalled: Bool
        public let tools: [Tool]

        public init(homebrewInstalled: Bool, tools: [Tool]) {
            self.homebrewInstalled = homebrewInstalled
            self.tools = tools
        }

        public var missingTools: [Tool] { tools.filter { !$0.isInstalled } }
        public var outdatedTools: [Tool] { tools.filter { $0.isInstalled && $0.isOutdated } }

        /// Every required tool is present (regardless of version).
        public var isReady: Bool { missingTools.isEmpty }

        /// Everything is present *and* current — the ideal "ready to work" state.
        public var isFullyReady: Bool { isReady && outdatedTools.isEmpty }

        /// Whether the app should surface the readiness banner to the user.
        public var needsAttention: Bool { !isFullyReady }

        /// Title for the one-click action button.
        public var actionTitle: String {
            isReady ? "Update Tools" : "Install Tools"
        }

        /// Short headline describing the current state.
        public var headline: String {
            if isFullyReady { return "All tools installed and up to date" }
            if !isReady { return "Required tools are missing" }
            return "Tool updates are available"
        }

        /// Human-readable detail line for the banner.
        public var summary: String {
            if isFullyReady {
                return "yt-dlp, ffmpeg, and fpcalc are installed via Homebrew and current."
            }

            var parts: [String] = []
            let missing = missingTools.map(\.displayName)
            if !missing.isEmpty {
                parts.append("Missing: \(missing.joined(separator: ", "))")
            }
            let outdated = outdatedTools.map(\.displayName)
            if !outdated.isEmpty {
                parts.append("Update available: \(outdated.joined(separator: ", "))")
            }

            var detail = parts.joined(separator: ". ")
            if !homebrewInstalled {
                detail += detail.isEmpty ? "" : ". "
                detail += "Homebrew is not installed; it will be set up automatically."
            }
            return detail
        }
    }

    /// Evaluates the current readiness of every required tool. Spawns short-lived
    /// subprocesses (`brew outdated`), so run it off the main thread.
    public static func evaluate() -> Report {
        let brewInstalled = HomebrewMaintenanceService.resolveBrewPath() != nil
        let outdated = Set(HomebrewMaintenanceService.outdatedManagedFormulae())

        let ytStatus = YouTubeAudioImportService.dependencyStatus()
        let fpcalcPath = AudioFingerprintService.fpcalcExecutablePath()

        let tools = [
            Tool(
                id: "yt-dlp",
                displayName: "yt-dlp",
                formula: "yt-dlp",
                isInstalled: ytStatus.ytDLPPath != nil,
                isOutdated: outdated.contains("yt-dlp")
            ),
            Tool(
                id: "ffmpeg",
                displayName: "ffmpeg",
                formula: "ffmpeg",
                isInstalled: ytStatus.ffmpegPath != nil,
                isOutdated: outdated.contains("ffmpeg")
            ),
            Tool(
                id: "fpcalc",
                displayName: "fpcalc (chromaprint)",
                formula: "chromaprint",
                isInstalled: fpcalcPath != nil,
                isOutdated: outdated.contains("chromaprint")
            )
        ]

        return Report(homebrewInstalled: brewInstalled, tools: tools)
    }

    /// Outcome of an install/upgrade run.
    public struct EnsureResult: Sendable {
        public let report: Report
        public let log: String

        public init(report: Report, log: String) {
            self.report = report
            self.log = log
        }
    }

    /// Installs Homebrew (if needed) plus any missing tools, and upgrades any
    /// outdated ones. Blocking and best-effort — run it off the main thread.
    /// Returns a fresh `Report` reflecting the result.
    public static func ensureReady() -> EnsureResult {
        var log = ""

        // Install Homebrew + yt-dlp + ffmpeg + chromaprint on a fresh machine.
        if let result = try? YouTubeAudioImportService.installDependencies() {
            log = result.log
        }

        // Upgrade any managed formulae that are behind (bypass the daily throttle).
        HomebrewMaintenanceService.refreshIfDue(force: true)

        // Keep the self-updating yt-dlp fallback current for machines without
        // Homebrew so YouTube downloads keep working regardless.
        YouTubeAudioImportService.refreshManagedYTDLPIfDue(force: true)

        return EnsureResult(report: evaluate(), log: log)
    }
}
