import SwiftUI
import AppKit
import SeratoToolsCore

struct LibraryBackupView: View {
    @EnvironmentObject private var libraryService: LibraryService

    @State private var destinationPath = ""
    @State private var selectedMode: LibraryBackupService.BackupMode = .full
    @State private var selectedCrateID: UUID?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var availableCrates: [Crate] {
        libraryService.crates + libraryService.smartCrates
    }

    private var selectedCrate: Crate? {
        guard let selectedCrateID else { return availableCrates.first }
        return availableCrates.first(where: { $0.id == selectedCrateID })
    }

    private var destinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: trimmed)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
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
        }
        .onChange(of: availableCrates.count) {
            if selectedCrateID == nil {
                selectedCrateID = availableCrates.first?.id
            }
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
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Destination")
                .font(.title.weight(.semibold))

            HStack(spacing: 10) {
                TextField("Destination folder", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    chooseDestinationFolder()
                }
            }

            Text("SeratoBackups will be created inside: \(destinationURL.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
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
    }

    private var summaryText: String {
        switch selectedMode {
        case .full:
            return "Will copy \(libraryService.tracks.count) track(s) and the full Serato folder."
        case .incremental:
            return "Will copy track files that are not already in the latest backup, plus the full Serato folder."
        case .singleCrate:
            if let selectedCrate {
                return "Will package \(selectedCrate.name.isEmpty ? selectedCrate.fileURL?.lastPathComponent ?? "the selected crate" : selectedCrate.name)."
            }
            return "Choose a crate to package."
        }
    }

    private var isActionDisabled: Bool {
        if selectedMode == .singleCrate {
            return availableCrates.isEmpty || selectedCrateID == nil
        }
        return libraryService.tracks.isEmpty
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = destinationURL

        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
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
}