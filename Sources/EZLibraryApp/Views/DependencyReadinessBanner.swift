import SwiftUI
import EZLibraryCore

/// Launch-time banner that reports whether the Homebrew-managed command-line
/// tools (yt-dlp, ffmpeg, fpcalc) are installed and current, with a one-click
/// action to install or update them.
struct DependencyReadinessBanner: View {
    @ObservedObject var model: DependencyReadinessModel

    var body: some View {
        if model.shouldShowBanner, let report = model.report {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: iconName(for: report))
                        .font(.title3)
                        .foregroundColor(tint(for: report))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.headline)
                            .font(.headline)
                        Text(report.summary)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isInstalling {
                            Text("Installing and updating tools via Homebrew. This can take a few minutes…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if model.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(report.actionTitle) {
                            Task { await model.installOrUpdate() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.isBannerDismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss until the next launch")
                    }
                }
                .padding(12)

                Divider()
            }
            .background(tint(for: report).opacity(0.10))
        }
    }

    private func iconName(for report: RuntimeDependencyService.Report) -> String {
        report.isReady ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func tint(for report: RuntimeDependencyService.Report) -> Color {
        report.isReady ? .orange : .red
    }
}
