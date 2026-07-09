import SwiftUI
import AppKit
import SeratoToolsCore

struct MissingTracksView: View {
    @EnvironmentObject private var libraryService: LibraryService
    @EnvironmentObject private var missingTracksService: MissingTracksService

    @State private var resultMessage: String?
    @State private var preferredLocationPath: String = ""
    @State private var showBulkDeleteUnmatchedConfirmation = false

    private static let preferredLocationDefaultsKey = "MissingTracksPreferredLocationPath"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderCard(
                title: "Missing Tracks",
                description: "Scan for moved or renamed files, then repair the missing entries or gather them into a review crate.",
                icon: "exclamationmark.triangle"
            )

            HStack {
                Text("\(missingTracksService.candidates.count) missing tracks")
                    .font(.headline)
                Spacer()
                if missingTracksService.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button("Scan for Matches") {
                    Task { await missingTracksService.scanForMatches() }
                }
                .disabled(missingTracksService.candidates.isEmpty || missingTracksService.isScanning)
                Button("Gather into Review Crate") {
                    gatherIntoCrate()
                }
                .disabled(missingTracksService.candidates.isEmpty)
            }
            .padding()

            HStack(spacing: 8) {
                TextField("Preferred track location", text: $preferredLocationPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    browseForPreferredLocation()
                }
                Button("Fix All (Preferred Location)") {
                    fixAllUsingPreferredLocation()
                }
                .disabled(missingTracksService.candidates.isEmpty || preferredLocationDirectory == nil)
                Button("Delete All (No Match)", role: .destructive) {
                    showBulkDeleteUnmatchedConfirmation = true
                }
                .disabled(
                    missingTracksService.candidates.isEmpty ||
                    !missingTracksService.hasScannedForMatches ||
                    unmatchedCandidateCount == 0
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Text(preferredLocationSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)

            List(missingTracksService.candidates) { candidate in
                MissingTrackRow(
                    candidate: candidate,
                    preferredDirectory: preferredLocationDirectory
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Missing Tracks")
        .task {
            missingTracksService.detectMissingTracks(in: libraryService.tracks)
            loadPreferredLocationIfNeeded()
        }
        .onChange(of: preferredLocationPath) {
            UserDefaults.standard.set(preferredLocationPath, forKey: Self.preferredLocationDefaultsKey)
        }
        .alert(
            "Missing Tracks",
            isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
        ) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog(
            "Delete All Unmatched Tracks?",
            isPresented: $showBulkDeleteUnmatchedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Unmatched Track References", role: .destructive) {
                deleteAllUnmatchedFromLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes missing tracks with no found match from Serato library metadata and crates. Audio files are not deleted.")
        }
        .padding(.horizontal, 8)
    }

    private func gatherIntoCrate() {
        do {
            let url = try missingTracksService.gatherIntoReviewCrate(subcratesDirectory: libraryService.subcratesDirectory)
            resultMessage = "Created \(url.lastPathComponent). Reload the library in Serato to see it."
            try? libraryService.reload()
        } catch {
            resultMessage = "Couldn't create the review crate: \(error.localizedDescription)"
        }
    }

    private var preferredLocationDirectory: URL? {
        let trimmed = preferredLocationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func loadPreferredLocationIfNeeded() {
        guard preferredLocationPath.isEmpty else { return }

        if let saved = UserDefaults.standard.string(forKey: Self.preferredLocationDefaultsKey), !saved.isEmpty {
            preferredLocationPath = saved
            return
        }

        preferredLocationPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .path
    }

    private func browseForPreferredLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where fixed tracks should be preferred from."
        panel.directoryURL = preferredLocationDirectory ?? URL(fileURLWithPath: preferredLocationPath)

        if panel.runModal() == .OK, let url = panel.url {
            preferredLocationPath = url.path
        }
    }

    private func fixAllUsingPreferredLocation() {
        guard let preferredDirectory = preferredLocationDirectory else {
            resultMessage = "Choose an existing preferred location first."
            return
        }

        do {
            let repairedCount = try missingTracksService.repairAllUsingPreferredLocation(preferredDirectory)
            if repairedCount == 0 {
                resultMessage = "No missing tracks had a match in \(preferredDirectory.path). Nothing was changed."
            } else {
                resultMessage = "Fixed \(repairedCount) tracks using matches found in \(preferredDirectory.path)."
            }
        } catch {
            resultMessage = "Couldn't fix tracks from preferred location: \(error.localizedDescription)"
        }
    }

    private func deleteAllUnmatchedFromLibrary() {
        guard missingTracksService.hasScannedForMatches else {
            resultMessage = "Scan for matches first, then bulk delete unmatched tracks."
            return
        }

        do {
            let deletedCount = try missingTracksService.deleteAllWithoutMatches(in: libraryService.crates)
            if deletedCount == 0 {
                resultMessage = "No unmatched tracks were found. Nothing was changed."
            } else if deletedCount == 1 {
                resultMessage = "Deleted 1 unmatched track reference from the library."
            } else {
                resultMessage = "Deleted \(deletedCount) unmatched track references from the library."
            }
            try? libraryService.reload()
        } catch {
            resultMessage = "Couldn't bulk delete unmatched tracks: \(error.localizedDescription)"
        }
    }

    private var unmatchedCandidateCount: Int {
        missingTracksService.candidates.filter { $0.matches.isEmpty }.count
    }

    private var preferredLocationSummaryText: String {
        guard let preferredDirectory = preferredLocationDirectory else {
            return "Choose a preferred location to see eligible fixes."
        }

        let eligibleCount = missingTracksService.candidates.filter {
            missingTracksService.preferredMatch(for: $0, preferredDirectory: preferredDirectory) != nil
        }.count

        if eligibleCount == 0 {
            if missingTracksService.hasScannedForMatches {
                return "0 tracks currently match the preferred location. \(unmatchedCandidateCount) tracks have no match."
            }
            return "0 tracks currently match the preferred location."
        }
        if eligibleCount == 1 {
            if missingTracksService.hasScannedForMatches {
                return "1 track can be fixed from the preferred location. \(unmatchedCandidateCount) tracks have no match."
            }
            return "1 track can be fixed from the preferred location."
        }
        if missingTracksService.hasScannedForMatches {
            return "\(eligibleCount) tracks can be fixed from the preferred location. \(unmatchedCandidateCount) tracks have no match."
        }
        return "\(eligibleCount) tracks can be fixed from the preferred location."
    }
}

private struct MissingTrackRow: View {
    @EnvironmentObject private var libraryService: LibraryService
    @EnvironmentObject private var missingTracksService: MissingTracksService
    let candidate: MissingTrackCandidate
    let preferredDirectory: URL?

    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(candidate.track.title.isEmpty ? candidate.track.fileURL.lastPathComponent : candidate.track.title)
                Text(candidate.track.seratoStoredPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionControl
        }
        .alert(
            "Couldn't Fix Track",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete from Library?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Track Reference", role: .destructive) {
                deleteFromLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the missing track from Serato library metadata and any crates that reference it. The audio file is not touched.")
        }
    }

    // Even a single unambiguous match requires an explicit click — a
    // same-filename match is a weaker signal than it looks (e.g. generic
    // filenames), so nothing here is ever auto-applied.
    @ViewBuilder
    private var actionControl: some View {
        if let preferredDirectory,
           let preferredMatch = missingTracksService.preferredMatch(for: candidate, preferredDirectory: preferredDirectory) {
            Button("Fix (Preferred)") { fix(using: preferredMatch) }
        } else {
            switch candidate.matches.count {
            case 0:
                HStack(spacing: 8) {
                    Text("No match found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete from Library", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            case 1:
                Button("Fix") { fix(using: candidate.matches[0]) }
            default:
                Menu("Fix (\(candidate.matches.count) matches)") {
                    ForEach(candidate.matches, id: \.self) { match in
                        Button(match.path) { fix(using: match) }
                    }
                }
            }
        }
    }

    private func fix(using url: URL) {
        do {
            try missingTracksService.repair(candidate, using: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteFromLibrary() {
        do {
            _ = try missingTracksService.deleteFromLibrary(candidate, in: libraryService.crates)
            try? libraryService.reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
