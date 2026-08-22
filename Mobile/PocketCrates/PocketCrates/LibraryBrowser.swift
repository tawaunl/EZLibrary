import SwiftUI
import EZLibrarySnapshotKit

// MARK: - Navigation scope

enum LibraryScope: Hashable {
    case allTracks
    case notInCrates
    case crate(SnapshotCrateNode)

    var title: String {
        switch self {
        case .allTracks:      return "All Tracks"
        case .notInCrates:    return "Not in Crates"
        case let .crate(node): return node.name
        }
    }
}

// MARK: - Library Browser

struct LibraryBrowser: View {
    let library: SnapshotLibrary
    let chooseFolder: () -> Void

    @Environment(SnapshotStore.self) private var store
    @AppStorage("hiddenCrateIDs") private var hiddenIDsRaw: String = ""
    @State private var showingHidden = false

    private var hiddenIDs: Set<String> {
        Set(hiddenIDsRaw.split(separator: ",").map(String.init))
    }

    private func hide(_ node: SnapshotCrateNode) {
        var ids = hiddenIDs
        ids.insert(node.id)
        hiddenIDsRaw = ids.joined(separator: ",")
    }

    private func unhide(_ node: SnapshotCrateNode) {
        var ids = hiddenIDs
        ids.remove(node.id)
        hiddenIDsRaw = ids.joined(separator: ",")
    }

    private var visibleCrates: [SnapshotCrateNode] {
        library.crateTree.filter { !hiddenIDs.contains($0.id) }
    }

    private var hiddenCrates: [SnapshotCrateNode] {
        library.crateTree.filter { hiddenIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: LibraryScope.allTracks) {
                        Label("All Tracks", systemImage: "music.note.list")
                            .badge(library.trackCount)
                    }
                    NavigationLink(value: LibraryScope.notInCrates) {
                        Label("Not in Crates", systemImage: "tray")
                            .badge(library.tracksNotInAnyCrate.count)
                    }
                }

                Section("Crates") {
                    ForEach(visibleCrates) { node in
                        CrateRow(node: node, onHide: { hide(node) })
                    }
                }

                if !hiddenCrates.isEmpty {
                    Section {
                        Button {
                            withAnimation { showingHidden.toggle() }
                        } label: {
                            Label(
                                showingHidden ? "Hide Hidden Crates" : "Show \(hiddenCrates.count) Hidden Crate\(hiddenCrates.count == 1 ? "" : "s")",
                                systemImage: showingHidden ? "eye.slash" : "eye"
                            )
                            .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)

                        if showingHidden {
                            ForEach(hiddenCrates) { node in
                                CrateRow(node: node, isHidden: true, onUnhide: { unhide(node) })
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent(
                        "Snapshot taken",
                        value: library.generatedAt.formatted(.relative(presentation: .named))
                    )
                    .font(.footnote)

                    Button("Check for a Newer Snapshot") { store.reload() }
                        .font(.footnote)

                    Button("Choose Another Folder", action: chooseFolder)
                        .font(.footnote)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryScope.self) { scope in
                TrackListView(library: library, scope: scope)
            }
            .navigationDestination(for: SnapshotTrack.self) { track in
                TrackDetailView(track: track)
            }
            .refreshable { store.reload() }
        }
    }
}

// MARK: - Crate Row

private struct CrateRow: View {
    let node: SnapshotCrateNode
    var isHidden: Bool = false
    var onHide: (() -> Void)? = nil
    var onUnhide: (() -> Void)? = nil

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: LibraryScope.crate(node)) {
                crateLabel(icon: "square.stack", count: node.trackPaths.count)
            }
            .contextMenu { contextMenuItems }
        } else {
            DisclosureGroup {
                NavigationLink(value: LibraryScope.crate(node)) {
                    crateLabel(
                        text: "Everything in \(node.name)",
                        icon: "square.stack.3d.up",
                        count: node.allTrackPaths.count
                    )
                }
                ForEach(node.children) { child in
                    CrateRow(node: child, onHide: onHide)
                }
            } label: {
                crateLabel(icon: "folder", count: node.allTrackPaths.count)
            }
            .contextMenu { contextMenuItems }
        }
    }

    @ViewBuilder
    private func crateLabel(text: String? = nil, icon: String, count: Int) -> some View {
        Label(text ?? node.name, systemImage: icon)
            .badge(count)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isHidden {
            Button { onUnhide?() } label: {
                Label("Show Crate", systemImage: "eye")
            }
        } else {
            Button(role: .destructive) { onHide?() } label: {
                Label("Hide Crate", systemImage: "eye.slash")
            }
        }
    }
}
