import SwiftUI
import AppKit
import SeratoToolsCore

struct LibraryConsolidationView: View {
    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var destinationPath = ""
    @State private var transferMode: LibraryConsolidationService.FileTransferMode = .move
    @State private var preview: LibraryConsolidationPreview?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isRunning = false
    @State private var destinationAvailableBytes: Int64?
    @State private var isRefreshingPreview = false
    @State private var previewRefreshTask: Task<Void, Never>?
    @State private var selectedSourceGroupIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                summaryRow
                destinationCard
                sourceGroupsCard
                destinationSpaceCard
            }
            .padding(16)
        }
        .task {
            if destinationPath.isEmpty {
                destinationPath = defaultDestinationFolder.path
            }
            schedulePreviewRefresh()
            refreshDestinationCapacity()
        }
        .onChange(of: libraryService.tracks.count) {
            schedulePreviewRefresh()
        }
        .onChange(of: destinationPath) {
            refreshDestinationCapacity()
        }
        .onDisappear {
            previewRefreshTask?.cancel()
            previewRefreshTask = nil
        }
    }

    private var defaultDestinationFolder: URL {
        libraryService.libraryDirectory
    }

    private var currentDestinationURL: URL {
        let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultDestinationFolder
        }
        return URL(fileURLWithPath: trimmed)
    }

    private var activePreview: LibraryConsolidationPreview? {
        guard let preview else { return nil }
        return LibraryConsolidationService.filteredPreview(preview, includingSourceGroupIDs: selectedSourceGroupIDs)
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
        .glowCardStyle(radius: 10, opacity: 0.08)
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
                    refreshDestinationCapacity()
                    schedulePreviewRefresh()
                }
            )

            HStack(spacing: 10) {
                Button("Refresh Preview") {
                    schedulePreviewRefresh()
                }
                .disabled(isRunning)
                Button(actionButtonTitle) {
                    runConsolidation()
                }
                .disabled(shouldDisableConsolidationAction)
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

                    Text("\(selectedSourceGroupIDs.count) selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 4) {
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

    private func refreshPreview() {
        schedulePreviewRefresh()
    }

    private func schedulePreviewRefresh() {
        previewRefreshTask?.cancel()

        let tracksSnapshot = libraryService.tracks
        let destinationSnapshot = currentDestinationURL

        isRefreshingPreview = true
        errorMessage = nil
        successMessage = nil

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
        if selectedSourceGroupIDs.contains(sourceGroupID) {
            selectedSourceGroupIDs.remove(sourceGroupID)
        } else {
            selectedSourceGroupIDs.insert(sourceGroupID)
        }
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
        guard let preview else {
            selectedSourceGroupIDs = []
            return
        }

        let allIDs = Set(preview.sourceGroups.map(\.id))
        switch sourceSelectionState {
        case .all:
            selectedSourceGroupIDs = []
        case .partial, .none:
            selectedSourceGroupIDs = allIDs
        }
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
            successMessage = "\(verb) \(result.processedTrackCount) track files into \(result.destinationFolderURL.lastPathComponent) and updated \(result.updatedCrateCount) crates."
            onLibraryChanged()
            refreshPreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}