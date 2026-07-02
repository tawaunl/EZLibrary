import SwiftUI
import AppKit
import SeratoToolsCore

enum SidebarSection: Hashable {
    case tracks
    case crates
    case missingTracks
}

struct ContentView: View {
    @EnvironmentObject private var libraryService: LibraryService
    @ObservedObject var crateHierarchy: CrateHierarchyViewModel
    @ObservedObject var smartCrateHierarchy: CrateHierarchyViewModel

    @State private var selectedSection: SidebarSection? = .tracks
    @State private var selectedCrateNode: CrateNode?
    @State private var loadErrorMessage: String?
    @State private var libraryPathDraft = ""

    var body: some View {
        HSplitView {
            List(selection: $selectedSection) {
                Label("Tracks", systemImage: "music.note.list").tag(SidebarSection.tracks)
                Label("Crates", systemImage: "square.stack").tag(SidebarSection.crates)
                Label("Missing Tracks", systemImage: "exclamationmark.triangle").tag(SidebarSection.missingTracks)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)

            switch selectedSection {
            case .tracks:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Library directory", text: $libraryPathDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { chooseLibraryDirectory() }
                        Button("Apply") { applyLibraryDirectory() }
                        Button("Reload") { reloadLibrary() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    Text("Using: \(libraryService.libraryDirectory.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    if let loadErrorMessage {
                        Text("Library load failed: \(loadErrorMessage)")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    } else if libraryService.tracks.isEmpty {
                        Text("No tracks loaded")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        Text("Loaded \(libraryService.tracks.count) tracks, \(libraryService.crates.count) crates, \(libraryService.smartCrates.count) smart crates")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    TrackTableView(tracks: libraryService.tracks, numberingMode: .listOrder)
                }
                .frame(minWidth: 320)
            case .crates:
                CrateTreeView(
                    crateHierarchy: crateHierarchy,
                    smartCrateHierarchy: smartCrateHierarchy,
                    selectedNode: $selectedCrateNode,
                    onCratesChanged: reloadLibrary
                )
                .frame(minWidth: 280)
            case .missingTracks:
                MissingTracksView()
                    .frame(minWidth: 320)
            case nil:
                Text("Select a section")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }

            Group {
                if selectedSection == .crates, let node = selectedCrateNode {
                    CrateDetailView(node: node, onCratesChanged: reloadLibrary)
                } else {
                    Text("Select an item")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            libraryPathDraft = libraryService.libraryDirectory.path
            reloadLibrary()
        }
    }

    private func reloadLibrary() {
        do {
            try libraryService.reload()
            loadErrorMessage = nil
            crateHierarchy.rebuild(from: libraryService.crates)
            smartCrateHierarchy.rebuild(from: libraryService.smartCrates)
        } catch {
            loadErrorMessage = error.localizedDescription
            crateHierarchy.rebuild(from: [])
            smartCrateHierarchy.rebuild(from: [])
            selectedCrateNode = nil
        }
    }

    private func chooseLibraryDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Library"
        panel.directoryURL = URL(fileURLWithPath: libraryPathDraft)

        if panel.runModal() == .OK, let url = panel.url {
            libraryPathDraft = url.path
            applyLibraryDirectory()
        }
    }

    private func applyLibraryDirectory() {
        let path = libraryPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        libraryService.setLibraryDirectory(url)
        UserDefaults.standard.set(path, forKey: SeratoLibraryLocator.libraryDirectoryDefaultsKey)
        reloadLibrary()
    }
}
