import SwiftUI
import EZLibrarySnapshotKit

// MARK: - Navigation scope

enum LibraryScope: Hashable {
    case allTracks
    case notInCrates
    case crate(SnapshotCrateNode)

    var title: String {
        switch self {
        case .allTracks:       return "All Tracks"
        case .notInCrates:     return "Not in Crates"
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
    @State private var showingPending = false

    // Alert state
    @State private var newCrateParent: SnapshotCrateNode? = nil  // nil = root level
    @State private var newCrateName = ""
    @State private var showNewCrateAlert = false

    @State private var crateToRename: SnapshotCrateNode? = nil
    @State private var renameCrateName = ""
    @State private var showRenameAlert = false

    @State private var crateToDelete: SnapshotCrateNode? = nil
    @State private var showDeleteAlert = false

    // MARK: Hidden crates

    private var hiddenIDs: Set<String> {
        Set(hiddenIDsRaw.split(separator: ",").map(String.init))
    }

    private func hide(_ node: SnapshotCrateNode) {
        var ids = hiddenIDs; ids.insert(node.id)
        hiddenIDsRaw = ids.joined(separator: ",")
    }

    private func unhide(_ node: SnapshotCrateNode) {
        var ids = hiddenIDs; ids.remove(node.id)
        hiddenIDsRaw = ids.joined(separator: ",")
    }

    private var visibleCrates: [SnapshotCrateNode] {
        library.crateTree.filter { !hiddenIDs.contains($0.id) }
    }

    private var hiddenCrates: [SnapshotCrateNode] {
        library.crateTree.filter { hiddenIDs.contains($0.id) }
    }

    // MARK: Body

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
                        CrateRow(
                            node: node,
                            onHide:        { hide(node) },
                            onRename:      { crateToRename = node; renameCrateName = node.name; showRenameAlert = true },
                            onDelete:      { crateToDelete = node; showDeleteAlert = true },
                            onNewSubcrate: { newCrateParent = node; newCrateName = ""; showNewCrateAlert = true }
                        )
                    }
                }

                if !hiddenCrates.isEmpty {
                    Section {
                        Button { withAnimation { showingHidden.toggle() } } label: {
                            Label(
                                showingHidden
                                    ? "Hide Hidden Crates"
                                    : "Show \(hiddenCrates.count) Hidden Crate\(hiddenCrates.count == 1 ? "" : "s")",
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.hasPendingIntents {
                        Button {
                            showingPending = true
                        } label: {
                            Label("Pending Changes", systemImage: "arrow.triangle.2.circlepath")
                                .symbolRenderingMode(.multicolor)
                        }
                        .overlay(alignment: .topTrailing) {
                            Text("\(store.pendingIntents.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.red, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newCrateParent = nil
                        newCrateName = ""
                        showNewCrateAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .refreshable { store.reload() }
            .alert("New Crate", isPresented: $showNewCrateAlert) {
                TextField("Crate name", text: $newCrateName)
                Button("Create") {
                    let name = newCrateName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    store.addIntent(.createCrate(
                        name: name,
                        parentPathComponents: newCrateParent?.pathComponents ?? []
                    ))
                    newCrateName = ""
                    newCrateParent = nil
                }
                Button("Cancel", role: .cancel) { newCrateName = ""; newCrateParent = nil }
            } message: {
                if let parent = newCrateParent {
                    Text("Enter a name for the new crate inside \"\(parent.name)\".")
                } else {
                    Text("Enter a name for the new crate.")
                }
            }
            .alert("Rename Crate", isPresented: $showRenameAlert) {
                TextField("New name", text: $renameCrateName)
                Button("Rename") {
                    let name = renameCrateName.trimmingCharacters(in: .whitespaces)
                    guard let node = crateToRename, !name.isEmpty, name != node.name else { return }
                    store.addIntent(.renameCrate(pathComponents: node.pathComponents, newName: name))
                    crateToRename = nil
                }
                Button("Cancel", role: .cancel) { crateToRename = nil }
            } message: {
                if let node = crateToRename {
                    Text("Enter a new name for \"\(node.name)\".")
                }
            }
            .alert("Delete Crate", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let node = crateToDelete {
                        store.addIntent(.deleteCrate(pathComponents: node.pathComponents))
                    }
                    crateToDelete = nil
                }
                Button("Cancel", role: .cancel) { crateToDelete = nil }
            } message: {
                if let node = crateToDelete {
                    Text("Delete \"\(node.name)\"? This will be applied to your Serato library on next sync. Sub-crates will also be removed.")
                }
            }
            .sheet(isPresented: $showingPending) {
                PendingIntentsView()
            }
        }
    }
}

// MARK: - Crate Row

private struct CrateRow: View {
    let node: SnapshotCrateNode
    var isHidden: Bool = false
    var onHide:        (() -> Void)? = nil
    var onUnhide:      (() -> Void)? = nil
    var onRename:      (() -> Void)? = nil
    var onDelete:      (() -> Void)? = nil
    var onNewSubcrate: (() -> Void)? = nil

    var body: some View {
        Group {
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
                        CrateRow(node: child, onHide: onHide, onRename: onRename,
                                 onDelete: onDelete, onNewSubcrate: onNewSubcrate)
                    }
                } label: {
                    Label(node.name, systemImage: "folder")
                }
            }
        }
        .contextMenu {
            if isHidden {
                Button { onUnhide?() } label: {
                    Label("Show Crate", systemImage: "eye")
                }
            } else {
                Button { onRename?() } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { onNewSubcrate?() } label: {
                    Label("New Sub-Crate", systemImage: "folder.badge.plus")
                }
                Divider()
                Button { onHide?() } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                Button(role: .destructive) { onDelete?() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
