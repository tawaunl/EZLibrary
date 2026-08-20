import SwiftUI
import EZLibrarySnapshotKit

/// What the track list is currently showing.
enum LibraryScope: Hashable {
    case allTracks
    case notInCrates
    case crate(SnapshotCrateNode)

    var title: String {
        switch self {
        case .allTracks: return "All Tracks"
        case .notInCrates: return "Not in Crates"
        case let .crate(node): return node.name
        }
    }
}

struct LibraryBrowser: View {
    let library: SnapshotLibrary
    let chooseFolder: () -> Void

    @Environment(SnapshotStore.self) private var store

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
                    ForEach(library.crateTree) { node in
                        CrateRow(node: node)
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

/// One crate in the sidebar. Nested crates expand in place; a crate with
/// children is still tappable because a parent crate can hold tracks as well.
private struct CrateRow: View {
    let node: SnapshotCrateNode

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: LibraryScope.crate(node)) {
                Label(node.name, systemImage: "square.stack")
                    .badge(node.trackPaths.count)
            }
        } else {
            DisclosureGroup {
                NavigationLink(value: LibraryScope.crate(node)) {
                    Label("Everything in \(node.name)", systemImage: "square.stack.3d.up")
                        .badge(node.allTrackPaths.count)
                }
                ForEach(node.children) { child in
                    CrateRow(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
        }
    }
}
