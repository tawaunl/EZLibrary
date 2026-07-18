import SwiftUI
import AppKit
import EZLibraryCore

struct AddMusicView: View {
    private enum CrateAssignmentMode: String, CaseIterable, Identifiable {
        case dated
        case named
        case existing
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dated:
                return "Dated Crate"
            case .named:
                return "Named Crate"
            case .existing:
                return "Existing Crate"
            case .none:
                return "No Additional Crate"
            }
        }
    }

    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var selectedInputURLs: [URL] = []
    @AppStorage(SeratoFeatureFlags.mainMusicFolderDefaultsKey) private var destinationPath = ""
    @State private var cratePrefix = "New Music"
    @AppStorage(SeratoFeatureFlags.addMusicUsesCentralCrateDefaultsKey) private var usesCentralCrate = false
    @AppStorage(SeratoFeatureFlags.addMusicCentralCrateIDDefaultsKey) private var selectedCentralCrateIDRaw = ""
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

    private var selectedCentralCrate: Crate? {
        guard let selectedCentralCrateID else { return nil }
        return availableCrates.first { $0.id == selectedCentralCrateID }
    }

    private var selectedCentralCrateID: UUID? {
        get { UUID(uuidString: selectedCentralCrateIDRaw) }
        nonmutating set { selectedCentralCrateIDRaw = newValue?.uuidString ?? "" }
    }

    private var isCrateSelectionValid: Bool {
        let isCentralCrateValid = !usesCentralCrate || selectedCentralCrate != nil

        switch crateAssignmentMode {
        case .dated, .named, .none:
            return isCentralCrateValid
        case .existing:
            return isCentralCrateValid && selectedExistingCrate != nil
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
            ensureDefaultCrateSelections()
            refreshDiscoveredCount()
        }
        .onChange(of: crateAssignmentMode) {
            guard crateAssignmentMode == .existing else { return }
            if selectedExistingCrateID == nil {
                selectedExistingCrateID = availableCrates.first?.id
            }
        }
        .onChange(of: usesCentralCrate) {
            guard usesCentralCrate else { return }
            if selectedCentralCrateID == nil {
                selectedCentralCrateID = availableCrates.first?.id
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Music")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Import files or folders into your main music folder, then optionally add them to your central crate workflow and also create or update another crate.")
                .foregroundStyle(.secondary)

            if let successMessage {
                SuccessBanner(message: successMessage) {
                    self.successMessage = nil
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: successMessage)
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
                .help("Scan the selected folder for audio files and add any missing tracks to the Serato database. Files are not moved, copied, or added to crates.")

                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .topTrailing) {
                        FastHoverHelp(
                            text: "Scans the selected folder for audio files and inserts missing tracks into Serato database V2. Existing tracks are left unchanged. It does not move/copy files or create crates."
                        )
                        .offset(x: 2, y: -2)
                    }
            }

            Toggle("Use central crate for Add Music", isOn: $usesCentralCrate)

            if usesCentralCrate {
                HStack(spacing: 10) {
                    Picker(
                        "Central Crate",
                        selection: Binding(
                            get: { selectedCentralCrateID?.uuidString ?? "" },
                            set: { newValue in
                                selectedCentralCrateID = UUID(uuidString: newValue)
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

                Text("When enabled, every Add Music import goes into this crate first, even if you also create or update another crate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Picker("Additional Crate", selection: $crateAssignmentMode) {
                    ForEach(CrateAssignmentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }

            if crateAssignmentMode == .dated || crateAssignmentMode == .named {
                HStack(spacing: 10) {
                    Text(crateAssignmentMode == .named ? "Crate Name" : "Crate Name Prefix")
                        .foregroundStyle(.secondary)
                    TextField("New Music", text: $cratePrefix)
                        .textFieldStyle(.roundedBorder)
                }
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

            if crateAssignmentMode == .dated {
                Text("Crate format: \(normalizedCratePrefix) YYYY-MM-DD")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if crateAssignmentMode == .named {
                Text("Crate format: \(normalizedCratePrefix)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if crateAssignmentMode == .none, usesCentralCrate {
                Text("Tracks will be added to the selected central crate only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if crateAssignmentMode == .none, !usesCentralCrate {
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
                .help("Choose audio files or folders to import into your library.")
                Button("Clear") {
                    selectedInputURLs = []
                    refreshDiscoveredCount()
                }
                .disabled(selectedInputURLs.isEmpty)
                .help("Remove all selected input files and folders.")
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
            .help("Copy or move the selected files into your library folder and add them to the Serato database.")

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
        let verb = transferMode == .move ? "Move" : "Copy"
        if usesCentralCrate {
            switch crateAssignmentMode {
            case .none:
                return "\(verb) + Add To Central Crate"
            default:
                return "\(verb) + Update Crates"
            }
        }

        switch crateAssignmentMode {
        case .dated:
            return "\(verb) + Create Dated Crate"
        case .named:
            return "\(verb) + Create Named Crate"
        case .existing:
            return "\(verb) + Add To Existing Crate"
        case .none:
            return "\(verb) + Import Only"
        }
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

    private func ensureDefaultCrateSelections() {
        if crateAssignmentMode == .existing, selectedExistingCrateID == nil {
            selectedExistingCrateID = availableCrates.first?.id
        }

        if usesCentralCrate, selectedCentralCrateID == nil {
            selectedCentralCrateID = availableCrates.first?.id
        }
    }

    private func crateAssignments(
        cratePrefix: String,
        usesCentralCrate: Bool,
        selectedCentralCrate: Crate?,
        crateAssignmentMode: CrateAssignmentMode,
        selectedExistingCrate: Crate?
    ) throws -> [AddMusicImportService.CrateAssignment] {
        var assignments: [AddMusicImportService.CrateAssignment] = []

        if usesCentralCrate {
            guard let selectedCentralCrate else {
                throw AddMusicImportService.ImportError.missingCrateFileURL
            }
            assignments.append(.existing(selectedCentralCrate))
        }

        switch crateAssignmentMode {
        case .dated:
            assignments.append(.dated(prefix: cratePrefix))
        case .named:
            assignments.append(.named(cratePrefix))
        case .existing:
            guard let selectedExistingCrate else {
                throw AddMusicImportService.ImportError.missingCrateFileURL
            }
            assignments.append(.existing(selectedExistingCrate))
        case .none:
            break
        }

        return assignments
    }

    private func successMessage(
        importedTrackCount: Int,
        crateResults: [AddMusicImportService.CrateCreationResult],
        insertedTracks: Int
    ) -> String {
        guard !crateResults.isEmpty else {
            return "Imported \(importedTrackCount) tracks with no crate assignment. Synced \(insertedTracks) new DB entries."
        }

        let crateNames = crateResults.map(\.crateName).joined(separator: ", ")
        let noun = crateResults.count == 1 ? "crate" : "crates"
        return "Imported \(importedTrackCount) tracks and updated \(noun) \(crateNames). Synced \(insertedTracks) new DB entries."
    }

    private func runImport() {
        guard !isImportDisabled else { return }

        isRunning = true
        errorMessage = nil
        successMessage = nil

        let inputURLs = selectedInputURLs
        let destinationFolder = destinationFolderURL
        let cratePrefix = normalizedCratePrefix
        let usesCentralCrate = usesCentralCrate
        let selectedCentralCrate = selectedCentralCrate
        let crateAssignmentMode = crateAssignmentMode
        let selectedExistingCrate = selectedExistingCrate
        let transferMode = transferMode
        let subcratesDirectory = libraryService.subcratesDirectory
        let databaseFileURL = libraryService.databaseFile
        let rootDirectory = libraryService.rootDirectory

        Task {
            do {
                let assignments = try crateAssignments(
                    cratePrefix: cratePrefix,
                    usesCentralCrate: usesCentralCrate,
                    selectedCentralCrate: selectedCentralCrate,
                    crateAssignmentMode: crateAssignmentMode,
                    selectedExistingCrate: selectedExistingCrate
                )

                let importedFiles = try await Task.detached(priority: .userInitiated) {
                    try AddMusicImportService.importAudioFiles(
                        inputURLs: inputURLs,
                        destinationFolderURL: destinationFolder,
                        transferMode: transferMode
                    )
                }.value

                let crateResults = try AddMusicImportService.assignAudioFiles(
                    importedFiles.importedFileURLs,
                    assignments: assignments,
                    subcratesDirectory: subcratesDirectory,
                    rootDirectory: rootDirectory
                )

                let syncResult = try LibraryFolderSyncService.syncAudioFiles(
                    importedFiles.importedFileURLs,
                    databaseFileURL: databaseFileURL,
                    rootDirectory: rootDirectory
                )

                successMessage = successMessage(
                    importedTrackCount: importedFiles.importedTrackCount,
                    crateResults: crateResults,
                    insertedTracks: syncResult.insertedTracks
                )

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
        let subcratesDirectory = libraryService.subcratesDirectory
        let usesCentralCrate = usesCentralCrate
        let selectedCentralCrate = selectedCentralCrate

        isSyncingFolder = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                let discoveredAudioFiles = AddMusicImportService.discoverAudioFiles(from: [folderURL])
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryFolderSyncService.syncAudioFolder(
                        folderURL,
                        databaseFileURL: databaseFileURL,
                        rootDirectory: rootDirectory
                    )
                }.value

                var crateResults: [AddMusicImportService.CrateCreationResult] = []
                if usesCentralCrate {
                    guard let selectedCentralCrate else {
                        throw AddMusicImportService.ImportError.missingCrateFileURL
                    }

                    crateResults = try AddMusicImportService.assignAudioFiles(
                        discoveredAudioFiles,
                        assignments: [.existing(selectedCentralCrate)],
                        subcratesDirectory: subcratesDirectory,
                        rootDirectory: rootDirectory
                    )
                }

                let baseMessage = "Scanned \(result.scannedAudioFiles) files. Inserted \(result.insertedTracks), already in library \(result.alreadyPresentTracks)."
                if let crateName = crateResults.first?.crateName {
                    successMessage = "\(baseMessage) Added tracks to crate \(crateName)."
                } else {
                    successMessage = baseMessage
                }
                onLibraryChanged()
            } catch {
                errorMessage = error.localizedDescription
            }

            isSyncingFolder = false
        }
    }
}

private struct FastHoverHelp: View {
    let text: String

    @State private var isHovering = false
    @State private var showPopover = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()

                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled, isHovering else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            showPopover = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.08)) {
                        showPopover = false
                    }
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                hoverTask = nil
            }
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                Text(text)
                    .font(.caption)
                    .frame(maxWidth: 300, alignment: .leading)
                    .padding(10)
            }
    }
}