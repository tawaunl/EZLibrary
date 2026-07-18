import SwiftUI
import AppKit
import EZLibraryCore

struct LibraryConsolidationView: View {
    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var libraryPathDraft = ""
    @AppStorage(SeratoFeatureFlags.mainMusicFolderDefaultsKey) private var destinationPath = ""
    @State private var transferMode: LibraryConsolidationService.FileTransferMode = .move
    @State private var preview: LibraryConsolidationPreview?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isRunning = false
    @State private var destinationAvailableBytes: Int64?
    @State private var isRefreshingPreview = false
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var selectedSourceGroupIDs: Set<String> = []
    @State private var activePreview: LibraryConsolidationPreview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                libraryLocationCard
                heroCard
                summaryRow
                destinationCard
                sourceGroupsCard
                destinationSpaceCard
            }
            .padding(16)
        }
        .task {
            if libraryPathDraft.isEmpty {
                libraryPathDraft = libraryService.libraryDirectory.path
            }
            if destinationPath.isEmpty {
                destinationPath = defaultDestinationFolder.path
            }
            schedulePreviewRefresh()
            refreshDestinationCapacity()
        }
        .onChange(of: libraryService.libraryDirectory.path) {
            libraryPathDraft = libraryService.libraryDirectory.path
            schedulePreviewRefresh()
        }
        .onChange(of: libraryService.tracks.count) {
            schedulePreviewRefresh()
        }
        .onChange(of: transferMode) {
            clearStatusMessages()
        }
        .onChange(of: destinationPath) {
            clearStatusMessages()
            refreshDestinationCapacity()
        }
        .onDisappear {
            previewRefreshTask?.cancel()
            previewRefreshTask = nil
        }
    }

    private var defaultDestinationFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var currentDestinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultDestinationFolder
        }
        return URL(fileURLWithPath: trimmed)
    }

    /// Recomputed explicitly at the few places `preview`/`selectedSourceGroupIDs`
    /// actually change, instead of being a computed property: `activePreview`
    /// is read from ~6 places across this view's body, and re-filtering
    /// `preview.moves`/`sourceGroups` (which can be large once a library is
    /// scattered across many folders) on every one of those reads on every
    /// render was the real cost — not the file-existence scan in `preview()`.
    private func updateActivePreview() {
        guard let preview else {
            activePreview = nil
            return
        }
        activePreview = LibraryConsolidationService.filteredPreview(preview, includingSourceGroupIDs: selectedSourceGroupIDs)
    }

    private enum SelectionState {
        case none
        case partial
        case all
    }

    private var sourceSelectionState: SelectionState {
        guard let preview, !preview.sourceGroups.isEmpty else {
            return .none
        }

        let allIDs = Set(preview.sourceGroups.map(\.id))
        let selectedCount = selectedSourceGroupIDs.intersection(allIDs).count
        if selectedCount == 0 {
            return .none
        }
        if selectedCount == allIDs.count {
            return .all
        }
        return .partial
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library Consolidation")
                .font(.system(size: 32, weight: .semibold, design: .default))
            Text("Map where your music is scattered, then copy or move everything into one central folder while rewriting Serato paths so crates and library references stay intact.")
                .font(.body)
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
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
        .glowCardStyle(radius: 10, opacity: 0.08)
    }

    private var libraryLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Main Serato Library")
                .font(.title.weight(.semibold))

            HStack(spacing: 10) {
                TextField("Library folder", text: $libraryPathDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    chooseLibraryDirectory()
                }
                .help("Choose the main Serato library folder.")
                Button("Apply") {
                    applyLibraryDirectory()
                }
                .help("Load the library from the entered folder path.")
            }
            .controlSize(.large)

            Text("Using: \(libraryService.libraryDirectory.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Central Folder")
                .font(.title.weight(.semibold))

            Picker("Transfer Mode", selection: $transferMode) {
                Text("Move Files").tag(LibraryConsolidationService.FileTransferMode.move)
                Text("Copy Files").tag(LibraryConsolidationService.FileTransferMode.copy)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)

            FinderFolderControls(
                label: "Destination folder",
                path: $destinationPath,
                browsePrompt: "Use Folder",
                browseStartURL: currentDestinationURL,
                allowsNewFolderCreation: true,
                onPathChanged: {
                    clearStatusMessages()
                    refreshDestinationCapacity()
                    schedulePreviewRefresh()
                }
            )

            HStack(spacing: 10) {
                Button("Refresh Preview") {
                    schedulePreviewRefresh()
                }
                .disabled(isRunning)
                .help("Recalculate which files would be moved or copied to the central folder.")
                Button(actionButtonTitle) {
                    runConsolidation()
                }
                .disabled(shouldDisableConsolidationAction)
                .help("Move or copy the selected source files into the central folder and update the library.")
            }
            .controlSize(.large)

            Text("Destination: \(currentDestinationURL.path)")
                .font(.callout)
                .foregroundStyle(.secondary)

            if transferMode == .copy, isCopyBlockedByCapacity {
                Text(copyModeDisableReason)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source Stats")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                summaryTag(title: "Source Locations", value: "\(activePreview?.sourceGroups.count ?? 0)", accent: true)
                summaryTag(title: "Tracks To Process", value: "\(activePreview?.totalMoves ?? 0)", accent: true)
                summaryTag(title: transferMode == .copy ? "Will Copy" : "Will Move", value: formatGB(activePreview?.queuedTransferBytes ?? 0), accent: true)
            }

            HStack(spacing: 10) {
                summaryTag(title: "Library Size", value: formatGB(activePreview?.totalExistingBytes ?? 0))
                summaryTag(title: "Already Centralized", value: formatGB(activePreview?.alreadyConsolidatedBytes ?? 0))
                summaryTag(title: "Copy Space Needed", value: formatGB(copyModeRequiredBytes))
            }
        }
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var destinationSpaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination Capacity")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                summaryTag(title: "Destination Free", value: destinationAvailableBytes.map(formatGB) ?? "Unknown")
                summaryTag(title: "Copy Space Needed", value: formatGB(copyModeRequiredBytes))
                summaryTag(title: "Space Check", value: spaceStatusLabel, accent: hasEnoughSpaceForCopy)
                Spacer(minLength: 0)
            }

            Text(spaceStatusDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private var sourceGroupsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Music Sources")
                .font(.title3.weight(.semibold))

            if let preview, !preview.sourceGroups.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        toggleSelectAllSources()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selectAllIconName)
                            Text("Select All Sources")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Select or deselect all source locations for consolidation.")

                    Text("\(selectedSourceGroupIDs.count) selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                LazyVStack(spacing: 4) {
                    ForEach(preview.sourceGroups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    toggleSourceSelection(group.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedSourceGroupIDs.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedSourceGroupIDs.contains(group.id) ? Color.accentColor : Color.secondary)
                                        Text(group.title)
                                            .font(.system(size: 18, weight: .semibold, design: .default))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Include or exclude this source location from consolidation.")

                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(group.trackCount) tracks")
                                        .font(.callout.weight(.semibold))
                                    Text(formatGB(group.totalBytes))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(group.examplePath)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    }
                }
            } else {
                Text("No track files are queued for movement with the current destination.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isRefreshingPreview {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing source analysis…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private func summaryTag(title: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(accent ? .white.opacity(0.92) : .secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .default))
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
        .glowCardStyle(radius: 8, opacity: 0.05)
    }

    private func chooseLibraryDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Library"
        panel.directoryURL = URL(fileURLWithPath: libraryPathDraft.trimmingCharacters(in: .whitespacesAndNewlines))

        if panel.runModal() == .OK, let url = panel.url {
            libraryPathDraft = url.path
            applyLibraryDirectory()
        }
    }

    private func applyLibraryDirectory() {
        let path = libraryPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        clearStatusMessages()
        libraryService.setLibraryDirectory(url)
        UserDefaults.standard.set(path, forKey: SeratoLibraryLocator.libraryDirectoryDefaultsKey)
        onLibraryChanged()
        schedulePreviewRefresh()
        refreshDestinationCapacity()
    }

    private var actionButtonTitle: String {
        transferMode == .copy ? "Copy + Update Serato" : "Move + Update Serato"
    }

    private var shouldDisableConsolidationAction: Bool {
        if isRunning || (activePreview?.moves.isEmpty ?? true) {
            return true
        }
        return isCopyBlockedByCapacity
    }

    private var copyModeRequiredBytes: Int64 {
        activePreview?.queuedTransferBytes ?? 0
    }

    private var hasEnoughSpaceForCopy: Bool {
        guard let available = destinationAvailableBytes else { return false }
        return available >= copyModeRequiredBytes
    }

    private var isCopyBlockedByCapacity: Bool {
        guard transferMode == .copy else { return false }
        guard let available = destinationAvailableBytes else { return false }
        return available < copyModeRequiredBytes
    }

    private var spaceStatusLabel: String {
        guard destinationAvailableBytes != nil else {
            return "Unknown"
        }
        return hasEnoughSpaceForCopy ? "Enough" : "Insufficient"
    }

    private var spaceStatusDetail: String {
        guard let available = destinationAvailableBytes else {
            return "Could not read destination volume free space."
        }

        if hasEnoughSpaceForCopy {
            let headroom = available - copyModeRequiredBytes
            return "Copy mode has enough free space with about \(formatGB(headroom)) headroom."
        }

        let shortfall = copyModeRequiredBytes - available
        return "Copy mode is short by about \(formatGB(shortfall)). Choose a different destination or free up disk space."
    }

    private var copyModeDisableReason: String {
        guard let available = destinationAvailableBytes, available < copyModeRequiredBytes else {
            return ""
        }

        let shortfall = copyModeRequiredBytes - available
        return "Copy disabled: destination is short by about \(formatGB(shortfall))."
    }

    private func formatGB(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GB", gigabytes)
    }

    private func clearStatusMessages() {
        successMessage = nil
        errorMessage = nil
    }

    private func refreshPreview() {
        schedulePreviewRefresh()
    }

    private func schedulePreviewRefresh() {
        previewRefreshTask?.cancel()

        let tracksSnapshot = libraryService.tracks
        let destinationSnapshot = currentDestinationURL

        // NOTE: do NOT clear `successMessage` here. This runs as part of the
        // post-run refresh (directly and via the tracks-count observer after
        // `onLibraryChanged()`), so clearing it would immediately wipe the
        // success banner set by `runConsolidation()`. Stale banners are instead
        // cleared via `clearStatusMessages()` on genuine user input changes.
        isRefreshingPreview = true
        errorMessage = nil

        previewRefreshTask = Task {
            let computedPreview = await Task.detached(priority: .userInitiated) {
                LibraryConsolidationService.preview(
                    tracks: tracksSnapshot,
                    destinationFolderURL: destinationSnapshot
                )
            }.value

            guard !Task.isCancelled else { return }
            preview = computedPreview
            selectedSourceGroupIDs = synchronizedSelection(for: computedPreview)
            updateActivePreview()
            isRefreshingPreview = false
        }
    }

    private func synchronizedSelection(for preview: LibraryConsolidationPreview) -> Set<String> {
        let available = Set(preview.sourceGroups.map(\ .id))
        guard !available.isEmpty else { return [] }

        if selectedSourceGroupIDs.isEmpty {
            return available
        }

        let retained = selectedSourceGroupIDs.intersection(available)
        return retained.isEmpty ? available : retained
    }

    private func toggleSourceSelection(_ sourceGroupID: String) {
        clearStatusMessages()
        if selectedSourceGroupIDs.contains(sourceGroupID) {
            selectedSourceGroupIDs.remove(sourceGroupID)
        } else {
            selectedSourceGroupIDs.insert(sourceGroupID)
        }
        updateActivePreview()
    }

    private var selectAllIconName: String {
        switch sourceSelectionState {
        case .all:
            return "checkmark.square.fill"
        case .partial:
            return "minus.square.fill"
        case .none:
            return "square"
        }
    }

    private func toggleSelectAllSources() {
        clearStatusMessages()
        guard let preview else {
            selectedSourceGroupIDs = []
            updateActivePreview()
            return
        }

        let allIDs = Set(preview.sourceGroups.map(\.id))
        switch sourceSelectionState {
        case .all:
            selectedSourceGroupIDs = []
        case .partial, .none:
            selectedSourceGroupIDs = allIDs
        }
        updateActivePreview()
    }

    private func refreshDestinationCapacity() {
        let referenceURL = existingAncestor(of: currentDestinationURL) ?? currentDestinationURL
        destinationAvailableBytes = detectedAvailableBytes(at: referenceURL)
    }

    private func detectedAvailableBytes(at referenceURL: URL) -> Int64? {
        let candidateFromResourceValues: Int64? = {
            do {
                let values = try referenceURL.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey,
                    .volumeAvailableCapacityForOpportunisticUsageKey,
                    .volumeAvailableCapacityKey
                ])
                if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                    return important
                }
                if let opportunistic = values.volumeAvailableCapacityForOpportunisticUsage, opportunistic > 0 {
                    return opportunistic
                }
                if let legacy = values.volumeAvailableCapacity, legacy > 0 {
                    return Int64(legacy)
                }
                return nil
            } catch {
                return nil
            }
        }()

        if let candidateFromResourceValues {
            return candidateFromResourceValues
        }

        // Fallback: file-system attributes are more reliable on some mounted
        // volumes and sandboxed contexts where URL resource values can report 0.
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: referenceURL.path),
           let freeSizeNumber = attributes[.systemFreeSize] as? NSNumber {
            let freeBytes = freeSizeNumber.int64Value
            if freeBytes > 0 {
                return freeBytes
            }
        }

        return nil
    }

    private func existingAncestor(of url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        let fileManager = FileManager.default

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: "/")
    }

    private func runConsolidation() {
        guard let activePreview else {
            schedulePreviewRefresh()
            return
        }

        errorMessage = nil
        successMessage = nil
        isRunning = true
        defer { isRunning = false }

        do {
            let result = try LibraryConsolidationService.consolidate(
                preview: activePreview,
                mode: transferMode,
                crates: libraryService.crates,
                rootDirectory: libraryService.rootDirectory,
                databaseFileURL: libraryService.databaseFile
            )
            let verb = result.mode == .copy ? "Copied" : "Moved"
            var message = "\(verb) \(result.processedTrackCount) track files into \(result.destinationFolderURL.lastPathComponent) and updated \(result.updatedCrateCount) crates."
            if result.skippedMissingCount > 0 {
                let fileWord = result.skippedMissingCount == 1 ? "file" : "files"
                message += " Skipped \(result.skippedMissingCount) missing source \(fileWord) that were no longer on disk."
            }
            successMessage = message
            onLibraryChanged()
            refreshPreview()
        } catch {
            if let localized = error as? LocalizedError,
               let suggestion = localized.recoverySuggestion,
               !suggestion.isEmpty {
                errorMessage = "\(error.localizedDescription)\n\n\(suggestion)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}