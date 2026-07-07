import SwiftUI
import AppKit
import SeratoToolsCore

struct LibraryBackupView: View {
    @EnvironmentObject private var libraryService: LibraryService

    @State private var destinationPath = ""
    @State private var selectedMode: LibraryBackupService.BackupMode = .full
    @State private var selectedCrateID: UUID?
    @State private var preview: LibraryBackupPreview?
    @State private var previewTask: Task<Void, Never>?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var availableCrates: [Crate] {
        libraryService.crates + libraryService.smartCrates
    }

    private var destinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var activePreview: LibraryBackupPreview? {
        preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                statsCard
                destinationCard
                modeCard
                actionCard
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = FileManager.default.homeDirectoryForCurrentUser.path
            }
            if selectedCrateID == nil {
                selectedCrateID = availableCrates.first?.id
            }
            refreshPreview()
        }
        .onChange(of: availableCrates.count) {
            if selectedCrateID == nil {
                selectedCrateID = availableCrates.first?.id
            }
            refreshPreview()
        }
        .onChange(of: destinationPath) {
            refreshPreview()
        }
        .onChange(of: selectedMode) {
            refreshPreview()
        }
        .onChange(of: selectedCrateID) {
            refreshPreview()
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Create a timestamped SeratoBackups folder at the destination you choose. Full backups copy the whole Serato library and all track files, incremental backups top up new tracks, and single-crate backups package one crate with its tracks.")
                .font(.body)
                .foregroundStyle(.secondary)

            if let successMessage {
                Text(successMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.16), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .glowCardStyle(radius: 10, opacity: 0.08)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pre-Backup Stats")
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            HStack(spacing: 14) {
                statTag(title: "Tracks", value: "\(activePreview?.trackCount ?? 0)")
                statTag(title: "Crates", value: "\(activePreview?.crateCount ?? 0)")
                statTag(title: "Backup Size", value: activePreview.map { formatBytes($0.estimatedByteCount) } ?? "--")
                Spacer(minLength: 0)
            }

            Text(statsDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .controlBackgroundColor).opacity(0.95), Color(nsColor: .windowBackgroundColor).opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .glowCardStyle(radius: 10, opacity: 0.08)
    }

    private func statTag(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(minWidth: 120, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        )
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Destination")
                .font(.title.weight(.semibold))

            FinderFolderControls(
                label: "Destination folder",
                path: $destinationPath,
                browsePrompt: "Use Folder",
                browseStartURL: destinationURL,
                allowsNewFolderCreation: true,
                onPathChanged: refreshPreview
            )

            Text("SeratoBackups will be created inside: \(destinationURL.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Mode")
                .font(.title3.weight(.semibold))

            Picker("Mode", selection: $selectedMode) {
                ForEach(LibraryBackupService.BackupMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if selectedMode == .singleCrate {
                Picker("Crate", selection: $selectedCrateID) {
                    ForEach(availableCrates) { crate in
                        Text(crate.name.isEmpty ? crate.fileURL?.lastPathComponent ?? "Crate" : crate.name)
                            .tag(Optional(crate.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(availableCrates.isEmpty)

                Text("Packages the selected crate file and the tracks it references.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to back up")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isRunning ? "Backing Up..." : "Create Backup") {
                    runBackup()
                }
                .disabled(isRunning || isActionDisabled)
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var summaryText: String {
        activePreview.map { preview in
            switch preview.mode {
            case .full:
                return "Will copy \(preview.trackCount) track(s) and the full Serato folder into \(preview.backupRootName)."
            case .incremental:
                return "Will top up the latest backup with new tracks and store it in \(preview.backupRootName)."
            case .singleCrate:
                let crateLabel = preview.crateName ?? "the selected crate"
                return "Will package \(crateLabel) into \(preview.backupRootName)."
            }
        } ?? "Builds a timestamped backup folder before you run it."
    }

    private var statsDetail: String {
        guard let preview = activePreview else {
            return "Choose a destination and backup mode to calculate the backup size."
        }

        switch preview.mode {
        case .full:
            return "Full backups include the whole Serato folder plus your track files."
        case .incremental:
            return "Incremental backups estimate the new track files plus the full Serato folder."
        case .singleCrate:
            return "Single-crate backups package one crate file and the tracks it references."
        }
    }

    private var isActionDisabled: Bool {
        if selectedMode == .singleCrate {
            return availableCrates.isEmpty || selectedCrateID == nil
        }
        return libraryService.tracks.isEmpty
    }

    private func refreshPreview() {
        previewTask?.cancel()

        let destination = destinationURL
        let mode = selectedMode
        let crateSelection = selectedCrateID
        let tracks = libraryService.tracks
        let crates = availableCrates
        let libraryDirectory = libraryService.libraryDirectory
        let rootDirectory = libraryService.rootDirectory

        previewTask = Task {
            do {
                let computedPreview = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.preview(
                        destinationFolderURL: destination,
                        mode: mode,
                        tracks: tracks,
                        crates: crates,
                        selectedCrateID: crateSelection,
                        libraryDirectory: libraryDirectory,
                        rootDirectory: rootDirectory
                    )
                }.value

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preview = computedPreview
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preview = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runBackup() {
        isRunning = true
        errorMessage = nil
        successMessage = nil

        let destination = destinationURL
        let mode = selectedMode
        let crateSelection = selectedCrateID
        let tracks = libraryService.tracks
        let crates = availableCrates
        let libraryDirectory = libraryService.libraryDirectory
        let rootDirectory = libraryService.rootDirectory

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.backup(
                        destinationFolderURL: destination,
                        mode: mode,
                        tracks: tracks,
                        crates: crates,
                        selectedCrateID: crateSelection,
                        libraryDirectory: libraryDirectory,
                        rootDirectory: rootDirectory
                    )
                }.value

                await MainActor.run {
                    isRunning = false
                    let note = result.note.map { " \($0)" } ?? ""
                    successMessage = "Backup created at \(result.backupRootURL.path).\(note)"
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GB", gigabytes)
    }
}
