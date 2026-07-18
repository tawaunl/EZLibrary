import SwiftUI
import EZLibraryCore

/// Drives the launch-time dependency readiness check and the banner that lets
/// the user install or update the Homebrew-managed command-line tools.
@MainActor
final class DependencyReadinessModel: ObservableObject {
    @Published private(set) var report: RuntimeDependencyService.Report?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var lastActionLog: String?
    @Published var isBannerDismissed = false

    /// Whether the readiness banner should currently be visible.
    var shouldShowBanner: Bool {
        if isInstalling { return true }
        guard !isBannerDismissed, let report else { return false }
        return report.needsAttention
    }

    /// Runs the readiness check every time the app launches.
    func checkOnLaunch() async {
        await refresh()
    }

    /// Re-evaluates readiness in the background and updates published state.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        let evaluated = await Task.detached(priority: .utility) {
            RuntimeDependencyService.evaluate()
        }.value
        report = evaluated
        // Re-surface the banner whenever a new problem appears.
        if evaluated.needsAttention {
            isBannerDismissed = false
        }
        isChecking = false
    }

    /// Installs missing tools and upgrades outdated ones, then re-evaluates.
    func installOrUpdate() async {
        guard !isInstalling else { return }
        isInstalling = true
        let result = await Task.detached(priority: .userInitiated) {
            RuntimeDependencyService.ensureReady()
        }.value
        report = result.report
        lastActionLog = result.log.isEmpty ? nil : result.log
        isInstalling = false
        if result.report.isFullyReady {
            isBannerDismissed = true
        }
    }
}
