import SwiftUI
import AppKit
import SeratoToolsCore

struct AddMusicView: View {
    private enum CrateAssignmentMode: String, CaseIterable, Identifiable {
        case dated
        case existing
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dated:
                return "Dated Crate"
            case .existing:
                return "Existing Crate"
            case .none:
                return "No Crate"
            }
        }
    }

    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var selectedInputURLs: [URL] = []
    @State private var destinationPath = ""
    @State private var cratePrefix = "New Music"
    @State private var crateAssignmentMode: CrateAssignmentMode = .dated
    @State private var selectedExistingCrateID: UUID?
    @State private var transferMode: AddMusicImportService.TransferMode = .move
    @State private var discoveredAudioCount = 0
    @State private var isRunning = false
    @State private var isSyncingFolder = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var destinationFolderURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultDestinationFolderURL
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var defaultDestinationFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var availableCrates: [Crate] {
        libraryService.crates.sorted {
            $0.pathComponents.joined(separator: " / ").localizedStandardCompare(
                $1.pathComponents.joined(separator: " / ")
            ) == .orderedAscending
        }
    }

    private var selectedExistingCrate: Crate? {
        guard let selectedExistingCrateID else { return nil }
        return availableCrates.first { $0.id == selectedExistingCrateID }
    }

    private var isCrateSelectionValid: Bool {
        switch crateAssignmentMode {
        case .dated, .none:
            return true
        case .existing:
            return selectedExistingCrate != nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                destinationCard
                sourceSelectionCard
                importSummaryCard
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = defaultDestinationFolderURL.path
            }
            refreshDiscoveredCount()
        }
        .onChange(of: crateAssignmentMode) {
            guard crateAssignmentMode == .existing else { return }
            if selectedExistingCrateID == nil {
                selectedExistingCrateID = availableCrates.first?.id
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Music")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Import files or folders into your main music folder, then create a fresh dated crate so the tracks are ready when you open Serato.")
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
                        colors: [Color.accentColor.opacity(0.18), Color(nsColor: .windowBackgroundColor)],
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
            Text("Destination + Crate")
                .font(.title3.weight(.semibold))

            Picker("Transfer", selection: $transferMode) {
                Text("Move Files").tag(AddMusicImportService.TransferMode.move)
                Text("Copy Files").tag(AddMusicImportService.TransferMode.copy)
            }
            .pickerStyle(.segmented)

            FinderFolderControls(
                label: "Main music folder",
                path: $destinationPath,
                browsePrompt: "Use Folder",
                browseStartURL: destinationFolderURL,
                allowsNewFolderCreation: true,
                onPathChanged: refreshDiscoveredCount
            )

            HStack(spacing: 10) {
                Button(isSyncingFolder ? "Syncing..." : "Sync Folder To Serato DB") {
                    syncDestinationFolderToSeratoLibrary()
                }
                .disabled(isRunning || isSyncingFolder)
            }

            HStack(spacing: 10) {
                Text("Crate Name Prefix")
                    .foregroundStyle(.secondary)
                TextField("New Music", text: $cratePrefix)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Picker("Crate Assignment", selection: $crateAssignmentMode) {
                    ForEach(CrateAssignmentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }

            if crateAssignmentMode == .existing {
                HStack(spacing: 10) {
                    Picker(
                        "Existing Crate",
                        selection: Binding(
                            get: { selectedExistingCrateID?.uuidString ?? "" },
                            set: { newValue in
                                selectedExistingCrateID = UUID(uuidString: newValue)
                            }
                        )
                    ) {
                        Text("Select Crate").tag("")
                        ForEach(availableCrates, id: \.id) { crate in
                            Text(crate.pathComponents.joined(separator: " / "))
                                .tag(crate.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
            }

            Text("Crate format: \(normalizedCratePrefix) YYYY-MM-DD")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if crateAssignmentMode == .none {
                Text("No crate will be updated for this import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var sourceSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source Files / Folders")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Button("Add Files/Folders...") {
                    chooseFilesAndFolders()
                }
                Button("Clear") {
                    selectedInputURLs = []
                    refreshDiscoveredCount()
                }
                .disabled(selectedInputURLs.isEmpty)
            }

            if selectedInputURLs.isEmpty {
                Text("No inputs selected.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selectedInputURLs, id: \.path) { url in
                        Text(url.path)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var importSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summaryTag(title: "Inputs", value: "\(selectedInputURLs.count)")
                summaryTag(title: "Audio Files Found", value: "\(discoveredAudioCount)", accent: true)
                summaryTag(title: "Mode", value: transferMode == .move ? "Move" : "Copy")
                Spacer(minLength: 0)
            }

            Button(actionTitle) {
                runImport()
            }
            .disabled(isImportDisabled)

            Text("Destination root: \(destinationFolderURL.path)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var normalizedCratePrefix: String {
        let trimmed = cratePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Music" : trimmed
    }

    private var actionTitle: String {
        if isRunning {
            return "Importing..."
        }
        return transferMode == .move ? "Move + Create Dated Crate" : "Copy + Create Dated Crate"
    }

    private var isImportDisabled: Bool {
        isRunning || isSyncingFolder || selectedInputURLs.isEmpty || discoveredAudioCount == 0 || !isCrateSelectionValid
    }

    private func summaryTag(title: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(accent ? .white.opacity(0.92) : .secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(accent ? .white : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func chooseFilesAndFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        if panel.runModal() == .OK {
            selectedInputURLs = mergedUniqueURLs(existing: selectedInputURLs, incoming: panel.urls)
            refreshDiscoveredCount()
        }
    }

    private func mergedUniqueURLs(existing: [URL], incoming: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []

        for url in (existing + incoming) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                output.append(url.standardizedFileURL)
            }
        }

        return output.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func refreshDiscoveredCount() {
        discoveredAudioCount = AddMusicImportService.discoverAudioFiles(from: selectedInputURLs).count
    }

    private func runImport() {
        guard !isImportDisabled else { return }

        isRunning = true
        errorMessage = nil
        successMessage = nil

        let inputURLs = selectedInputURLs
        let destinationFolder = destinationFolderURL
        let cratePrefix = normalizedCratePrefix
        let crateAssignmentMode = crateAssignmentMode
        let selectedExistingCrate = selectedExistingCrate
        let transferMode = transferMode
        let subcratesDirectory = libraryService.subcratesDirectory
        let rootDirectory = libraryService.rootDirectory

        Task {
            do {
                switch crateAssignmentMode {
                case .dated:
                    let result = try await Task.detached(priority: .userInitiated) {
                        try AddMusicImportService.importIntoDatedCrate(
                            inputURLs: inputURLs,
                            destinationFolderURL: destinationFolder,
                            crateNamePrefix: cratePrefix,
                            transferMode: transferMode,
                            subcratesDirectory: subcratesDirectory,
                            rootDirectory: rootDirectory
                        )
                    }.value

                    successMessage = "Imported \(result.importedTrackCount) tracks and created crate \(result.crateName)."
                case .existing:
                    guard let selectedExistingCrate else {
                        throw AddMusicImportService.ImportError.missingCrateFileURL
                    }
                    let importedFiles = try await Task.detached(priority: .userInitiated) {
                        try AddMusicImportService.importAudioFiles(
                            inputURLs: inputURLs,
                            destinationFolderURL: destinationFolder,
                            transferMode: transferMode
                        )
                    }.value

                    let crateResult = try AddMusicImportService.appendAudioFiles(
                        importedFiles.importedFileURLs,
                        toExistingCrate: selectedExistingCrate,
                        rootDirectory: rootDirectory
                    )

                    successMessage = "Imported \(importedFiles.importedTrackCount) tracks and saved to crate \(crateResult.crateName)."
                case .none:
                    let importedFiles = try await Task.detached(priority: .userInitiated) {
                        try AddMusicImportService.importAudioFiles(
                            inputURLs: inputURLs,
                            destinationFolderURL: destinationFolder,
                            transferMode: transferMode
                        )
                    }.value

                    successMessage = "Imported \(importedFiles.importedTrackCount) tracks with no crate assignment."
                }

                onLibraryChanged()
                selectedInputURLs = []
                refreshDiscoveredCount()
            } catch {
                errorMessage = error.localizedDescription
            }

            isRunning = false
        }
    }

    private func syncDestinationFolderToSeratoLibrary() {
        let folderURL = destinationFolderURL
        let databaseFileURL = libraryService.databaseFile
        let rootDirectory = libraryService.rootDirectory

        isSyncingFolder = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryFolderSyncService.syncAudioFolder(
                        folderURL,
                        databaseFileURL: databaseFileURL,
                        rootDirectory: rootDirectory
                    )
                }.value

                successMessage = "Scanned \(result.scannedAudioFiles) files. Inserted \(result.insertedTracks), already in library \(result.alreadyPresentTracks)."
                onLibraryChanged()
            } catch {
                errorMessage = error.localizedDescription
            }

            isSyncingFolder = false
        }
    }
}