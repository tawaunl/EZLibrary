import AppKit
import SwiftUI
import SeratoToolsCore

/// Drives the "Check for Updates" flow and owns its presentation state.
@MainActor
final class UpdateCheckViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String)
        case updateAvailable(AppReleaseInfo)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var isPresented = false

    /// Progress of an in-app installer download/launch.
    enum InstallPhase: Equatable {
        case idle
        case downloading(Double)
        case readyToInstall(URL)
        case installing
        case failed(String)
    }

    @Published var installPhase: InstallPhase = .idle

    /// How often the app checks automatically in the background.
    static let automaticCheckInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let lastAutomaticCheckDefaultsKey = "SeratoToolsLastAutomaticUpdateCheck"

    private let service: UpdateCheckService
    private let defaults: UserDefaults

    init(service: UpdateCheckService = UpdateCheckService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var currentVersion: String {
        UpdateCheckService.bundleVersion() ?? "unknown"
    }

    /// Presents the sheet and starts a check.
    func startCheck() {
        isPresented = true
        Task { await check() }
    }

    func check() async {
        phase = .checking
        do {
            let result = try await service.checkForUpdates()
            defaults.set(Date(), forKey: Self.lastAutomaticCheckDefaultsKey)
            switch result {
            case .upToDate(let currentVersion, _):
                phase = .upToDate(currentVersion: currentVersion)
            case .updateAvailable(_, let latest):
                phase = .updateAvailable(latest)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    /// Runs a silent weekly check. The sheet is only presented when a newer
    /// version is available; "up to date" and failures stay quiet.
    func runAutomaticCheckIfDue() async {
        if let lastCheck = defaults.object(forKey: Self.lastAutomaticCheckDefaultsKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return
        }

        do {
            let result = try await service.checkForUpdates()
            defaults.set(Date(), forKey: Self.lastAutomaticCheckDefaultsKey)
            if case .updateAvailable(_, let latest) = result {
                phase = .updateAvailable(latest)
                isPresented = true
            }
        } catch {
            // Silent for automatic checks; the user can retry manually from the menu.
        }
    }

    /// Downloads the release's `.pkg` installer and opens it so the user can
    /// complete the update through the standard macOS installer.
    func installUpdate(_ release: AppReleaseInfo) {
        guard let url = release.installerDownloadURL else {
            // No installer asset — fall back to the release page.
            NSWorkspace.shared.open(release.releasePageURL)
            return
        }
        installPhase = .downloading(0)
        Task { await performInstall(from: url) }
    }

    private func performInstall(from url: URL) async {
        let downloader = InstallerDownloader()
        do {
            let fileURL = try await downloader.download(from: url) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.installPhase {
                        self.installPhase = .downloading(progress)
                    }
                }
            }
            installPhase = .readyToInstall(fileURL)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            installPhase = .failed(message)
        }
    }

    /// Installs the downloaded `.pkg` with an admin prompt, then quits and
    /// relaunches EZLibrary automatically once the install finishes.
    func installAndRelaunch(pkgURL: URL) {
        do {
            try AppUpdateInstaller.installAndRelaunch(pkgURL: pkgURL)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            installPhase = .failed(message)
            return
        }
        installPhase = .installing
        // Give the detached updater script a moment to start waiting on our PID,
        // then quit so the installer can replace the running app bundle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    /// Opens the downloaded installer in the standard macOS Installer (no auto-relaunch).
    func openInstallerManually(pkgURL: URL) {
        NSWorkspace.shared.open(pkgURL)
    }
}

/// Writes and launches a detached script that waits for EZLibrary to quit,
/// installs the downloaded package with administrator privileges, and reopens
/// the app.
enum AppUpdateInstaller {
    static func installAndRelaunch(pkgURL: URL) throws {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // $PKG / $APP / $PID are shell variables (not Swift interpolation).
        // The doubled backslashes escape the quotes for the osascript argument.
        let script = """
        #!/bin/bash
        PKG="$1"
        APP="$2"
        PID="$3"

        # Wait (up to ~60s) for EZLibrary to fully quit.
        for _ in $(seq 1 120); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.5
        done

        # Install with a single administrator prompt.
        /usr/bin/osascript -e "do shell script \\"/usr/sbin/installer -pkg '$PKG' -target /\\" with administrator privileges"

        # Reopen the (now updated) app and clean up.
        /usr/bin/open "$APP"
        /bin/rm -f "$PKG"
        /bin/rm -f "$0"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seratotools-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, pkgURL.path, appPath, String(pid)]
        try process.run()
    }
}

/// Downloads a file to a temporary location, reporting progress.
private final class InstallerDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    func download(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progressHandler = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("EZLibrary", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let continuation else { return }
        self.continuation = nil
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("EZLibrary-Update-\(UUID().uuidString).pkg")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume(returning: destination)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

struct UpdateCheckView: View {
    @ObservedObject var viewModel: UpdateCheckViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Software Update")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            content

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed version \(viewModel.currentVersion)")
                    Text("Not affiliated with Serato Audio Research.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

        case .upToDate(let currentVersion):
            VStack(alignment: .leading, spacing: 6) {
                Label("You're up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("EZLibrary \(currentVersion) is the latest version.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 10) {
                Label("Update available", systemImage: "sparkles")
                    .foregroundStyle(.tint)
                    .font(.headline)
                Text("EZLibrary \(release.version) is available.")
                    .foregroundStyle(.secondary)

                if !release.releaseNotes.isEmpty {
                    ScrollView {
                        Text(release.releaseNotes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                installControls(for: release)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await viewModel.check() }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func installControls(for release: AppReleaseInfo) -> some View {
        switch viewModel.installPhase {
        case .idle:
            HStack(spacing: 10) {
                Button("Update Now") {
                    viewModel.installUpdate(release)
                }
                .buttonStyle(.borderedProminent)

                Button("View Release Notes") {
                    NSWorkspace.shared.open(release.releasePageURL)
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading update…")
                    .font(.callout)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .readyToInstall(let pkgURL):
            VStack(alignment: .leading, spacing: 8) {
                Label("Ready to install", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                Text("EZLibrary will quit, install the update (you'll be asked for your password), and reopen automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Install & Relaunch") {
                        viewModel.installAndRelaunch(pkgURL: pkgURL)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Installer Manually") {
                        viewModel.openInstallerManually(pkgURL: pkgURL)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Quitting to install… EZLibrary will reopen when the update finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Try Again") {
                        viewModel.installUpdate(release)
                    }
                    .buttonStyle(.borderedProminent)
                    if let downloadURL = release.installerDownloadURL {
                        Button("Download in Browser") {
                            NSWorkspace.shared.open(downloadURL)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
