import SwiftUI
import AppKit
import SeratoToolsCore

struct CrateTreeView: View {
    @EnvironmentObject private var libraryService: LibraryService
    @ObservedObject var crateHierarchy: CrateHierarchyViewModel
    @ObservedObject var smartCrateHierarchy: CrateHierarchyViewModel
    @Binding var selectedNode: CrateNode?
    let onCratesChanged: () -> Void

    @State private var searchText = ""
    @State private var pendingDelete: (node: CrateNode, viewModel: CrateHierarchyViewModel)?
    @State private var deleteErrorMessage: String?
    @State private var crateCreateError: String?

    var body: some View {
        VStack(spacing: 8) {
            TextField("Filter crates", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            HStack {
                Button("New Crate") { promptCreateCrate() }
                Spacer()
            }
            .padding(.horizontal, 8)

            List(selection: $selectedNode) {
                Section("Crates") {
                    OutlineGroup(crateHierarchy.visibleTree, children: \.outlineChildren) { node in
                        row(for: node, in: crateHierarchy).tag(node)
                    }
                }

                if !smartCrateHierarchy.visibleTree.isEmpty {
                    Section("Smart Crates") {
                        OutlineGroup(smartCrateHierarchy.visibleTree, children: \.outlineChildren) { node in
                            row(for: node, in: smartCrateHierarchy).tag(node)
                        }
                    }
                }

                let hidden = crateHierarchy.hiddenNodes + smartCrateHierarchy.hiddenNodes
                if !hidden.isEmpty {
                    Section {
                        DisclosureGroup("Hidden (\(hidden.count))") {
                            ForEach(hidden) { node in
                                HStack {
                                    Text(node.name)
                                    Spacer()
                                    Button("Unhide") { unhide(node) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            crateHierarchy.searchText = newValue
            smartCrateHierarchy.searchText = newValue
        }
        .alert(
            "Delete Crate?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pendingDelete {
                let count = pendingDelete.viewModel.deletionCount(for: pendingDelete.node)
                Text("This will move \(count) crate file\(count == 1 ? "" : "s") to the Trash.")
            }
        }
        .alert(
            "Couldn't Delete Crate",
            isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
        ) {
            Button("OK") { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            "Couldn't Create Crate",
            isPresented: Binding(get: { crateCreateError != nil }, set: { if !$0 { crateCreateError = nil } })
        ) {
            Button("OK") { crateCreateError = nil }
        } message: {
            Text(crateCreateError ?? "")
        }
    }

    @ViewBuilder
    private func row(for node: CrateNode, in viewModel: CrateHierarchyViewModel) -> some View {
        Text(node.name)
            .contextMenu {
                Button("Hide") { viewModel.hide(node) }
                if viewModel.allowsDelete {
                    Button("Delete…", role: .destructive) {
                        pendingDelete = (node, viewModel)
                    }
                }
            }
    }

    private func unhide(_ node: CrateNode) {
        if crateHierarchy.hiddenNodes.contains(node) {
            crateHierarchy.unhide(node)
        } else {
            smartCrateHierarchy.unhide(node)
        }
    }

    private func confirmDelete() {
        guard let pendingDelete else { return }
        do {
            try pendingDelete.viewModel.delete(pendingDelete.node)
            if selectedNode == pendingDelete.node {
                selectedNode = nil
            }
            onCratesChanged()
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
        self.pendingDelete = nil
    }

    private func promptCreateCrate() {
        let alert = NSAlert()
        alert.messageText = "Create Crate"
        alert.informativeText = "Enter a crate name. Use \(Crate.nestingDelimiter) between segments for subcrates."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "New Crate"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let baseName = Crate.fileBaseName(forPathComponents: Crate.pathComponents(forCrateFileNamed: name))
            let destination = libraryService.subcratesDirectory.appendingPathComponent(baseName).appendingPathExtension("crate")
            if FileManager.default.fileExists(atPath: destination.path) {
                throw NSError(domain: "SeratoTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "A crate with that name already exists."])
            }
            try SeratoCrateEditor.createCrate(at: destination)
            onCratesChanged()
        } catch {
            crateCreateError = error.localizedDescription
        }
    }
}

private extension CrateNode {
    var outlineChildren: [CrateNode]? { children.isEmpty ? nil : children }
}
