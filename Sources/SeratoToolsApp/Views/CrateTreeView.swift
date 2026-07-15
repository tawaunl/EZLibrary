import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SeratoToolsCore

enum CrateListFilterMode {
    case all
    case hiddenOnly
    case smartOnly
}

struct CrateTreeView: View {
    private static let hiddenRootFolderName = "SeratoTools Hidden Crates"
    private static let hiddenSubcratesFolderName = "Subcrates"
    private static let hiddenSmartCratesFolderName = "SmartCrates"
    private static let seratoBlue = Color(red: 0.10, green: 0.43, blue: 0.89)

    @EnvironmentObject private var libraryService: LibraryService
    @ObservedObject var crateHierarchy: CrateHierarchyViewModel
    @ObservedObject var smartCrateHierarchy: CrateHierarchyViewModel
    @Binding var selectedNode: CrateNode?
    let listFilterMode: CrateListFilterMode
    let onCratesChanged: () -> Void

    @State private var searchText = ""
    @State private var pendingDelete: (node: CrateNode, viewModel: CrateHierarchyViewModel)?
    @State private var deleteErrorMessage: String?
    @State private var crateCreateError: String?
    @State private var hideSyncErrorMessage: String?
    @State private var dropErrorMessage: String?
    @State private var dropTargetNodeID: String?
    @State private var showingInlineCreate = false
    @State private var newCrateName = ""
    @FocusState private var isInlineCreateNameFocused: Bool

    private var combinedVisibleTree: [CrateNode] {
        mergedTrees(crateHierarchy.visibleTree, smartCrateHierarchy.visibleTree)
    }

    private var regularNodesByID: [String: CrateNode] {
        crateHierarchy.visibleNodesByID
    }

    private var smartNodesByID: [String: CrateNode] {
        smartCrateHierarchy.visibleNodesByID
    }

    private var hiddenNodes: [CrateNode] {
        dedupedByID(crateHierarchy.hiddenNodes + smartCrateHierarchy.hiddenNodes)
    }

    private var filteredHiddenNodes: [CrateNode] {
        guard !searchText.isEmpty else { return hiddenNodes }
        return hiddenNodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedRegularNode: CrateNode? {
        guard let selectedNode else { return nil }
        return regularNodesByID[selectedNode.id]
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Filter crates", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .onTapGesture {
                    NSApp.activate(ignoringOtherApps: true)
                }

            HStack {
                Button("New Crate") {
                    newCrateName = ""
                    showingInlineCreate = true
                    DispatchQueue.main.async {
                        isInlineCreateNameFocused = true
                    }
                }
                .help("Create a new empty crate.")
                Button("Hide") {
                    hideSelectedCrate()
                }
                .disabled(selectedNode == nil)
                .help("Hide the selected crate from the main list without deleting it.")

                Button("Delete") {
                    requestDeleteSelectedCrate()
                }
                .disabled(selectedRegularNode == nil)
                .help("Permanently delete the selected crate.")
                Spacer()
            }
            .padding(.horizontal, 8)

            if showingInlineCreate {
                HStack(spacing: 8) {
                    TextField("New Crate", text: $newCrateName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isInlineCreateNameFocused)
                        .onSubmit {
                            createCrateInline()
                        }

                    Button("Create") {
                        createCrateInline()
                    }
                    .disabled(newCrateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Create the crate with the entered name.")

                    Button("Cancel") {
                        newCrateName = ""
                        showingInlineCreate = false
                    }
                    .help("Cancel creating a new crate.")
                }
                .padding(.horizontal, 8)
            }

            List(selection: $selectedNode) {
                if listFilterMode == .hiddenOnly {
                    Section("Hidden Crates") {
                        ForEach(filteredHiddenNodes) { node in
                            HStack {
                                Text(node.name)
                                Spacer()
                                Button("Unhide") { unhide(node) }
                                    .buttonStyle(.bordered)
                                    .help("Show this crate in the main list again.")
                            }
                        }
                    }
                } else if listFilterMode == .smartOnly {
                    Section("Smart Crates") {
                        OutlineGroup(smartCrateHierarchy.visibleTree, children: \.outlineChildren) { node in
                            row(for: node).tag(node)
                        }
                    }
                } else {
                    Section("Crates") {
                        OutlineGroup(combinedVisibleTree, children: \.outlineChildren) { node in
                            row(for: node).tag(node)
                        }
                    }

                    if !hiddenNodes.isEmpty {
                        Section {
                            DisclosureGroup("Hidden (\(hiddenNodes.count))") {
                                ForEach(hiddenNodes) { node in
                                    HStack {
                                        Text(node.name)
                                        Spacer()
                                        Button("Unhide") { unhide(node) }
                                            .buttonStyle(.bordered)
                                            .help("Show this crate in the main list again.")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .onDeleteCommand {
                requestDeleteSelectedCrate()
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
        .alert(
            "Couldn't Change Crate Visibility",
            isPresented: Binding(get: { hideSyncErrorMessage != nil }, set: { if !$0 { hideSyncErrorMessage = nil } })
        ) {
            Button("OK") { hideSyncErrorMessage = nil }
        } message: {
            Text(hideSyncErrorMessage ?? "")
        }
        .alert(
            "Couldn't Add Tracks To Crate",
            isPresented: Binding(get: { dropErrorMessage != nil }, set: { if !$0 { dropErrorMessage = nil } })
        ) {
            Button("OK") { dropErrorMessage = nil }
        } message: {
            Text(dropErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for node: CrateNode) -> some View {
        HStack(spacing: 6) {
            Text(node.name)
            if let badge = smartBadgeKind(for: node) {
                Text(badge.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(
                        Capsule()
                            .fill(badge.color)
                    )
                    .help(badge.helpText)
            }
            Spacer(minLength: 0)
        }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(dropTargetNodeID == node.id ? Self.seratoBlue.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(dropTargetNodeID == node.id ? Self.seratoBlue.opacity(0.92) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onDrop(of: [UTType.plainText.identifier], isTargeted: dropTargetBinding(for: node)) { providers in
                handleTrackDrop(providers, onto: node)
            }
            .contextMenu {
                Button("Hide") { hide(node) }
                if let regularNode = regularNodesByID[node.id] {
                    Button("Delete…", role: .destructive) {
                        pendingDelete = (regularNode, crateHierarchy)
                    }
                }
            }
    }

    private func dropTargetBinding(for node: CrateNode) -> Binding<Bool> {
        Binding(
            get: { dropTargetNodeID == node.id },
            set: { isTargeted in
                dropTargetNodeID = isTargeted ? node.id : (dropTargetNodeID == node.id ? nil : dropTargetNodeID)
            }
        )
    }

    private func unhide(_ node: CrateNode) {
        do {
            try unhideOnDisk(node)
            crateHierarchy.unhide(node)
            smartCrateHierarchy.unhide(node)
            onCratesChanged()
        } catch {
            hideSyncErrorMessage = error.localizedDescription
        }
    }

    private func hide(_ node: CrateNode) {
        do {
            try hideOnDisk(node)
            crateHierarchy.hide(node)
            smartCrateHierarchy.hide(node)
            onCratesChanged()
        } catch {
            hideSyncErrorMessage = error.localizedDescription
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

    private func hideSelectedCrate() {
        guard let selectedNode else { return }
        hide(selectedNode)
    }

    private func requestDeleteSelectedCrate() {
        guard let selectedRegularNode else { return }
        pendingDelete = (selectedRegularNode, crateHierarchy)
    }

    private func createCrateInline() {
        let name = newCrateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let baseName = Crate.fileBaseName(forPathComponents: Crate.pathComponents(forCrateFileNamed: name))
            let destination = libraryService.subcratesDirectory.appendingPathComponent(baseName).appendingPathExtension("crate")
            if FileManager.default.fileExists(atPath: destination.path) {
                throw NSError(domain: "SeratoTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "A crate with that name already exists."])
            }
            try SeratoCrateEditor.createCrate(at: destination)
            newCrateName = ""
            showingInlineCreate = false
            onCratesChanged()
        } catch {
            crateCreateError = error.localizedDescription
        }
    }

    private func mergedTrees(_ regular: [CrateNode], _ smart: [CrateNode]) -> [CrateNode] {
        var merged: [String: CrateNode] = [:]
        var order: [String] = []

        func insert(_ node: CrateNode) {
            if let existing = merged[node.id] {
                var combined = existing
                if combined.crate == nil {
                    combined.crate = node.crate
                }
                combined.children = mergedTrees(combined.children, node.children)
                merged[node.id] = combined
            } else {
                merged[node.id] = node
                order.append(node.id)
            }
        }

        for node in regular { insert(node) }
        for node in smart { insert(node) }

        return order.compactMap { merged[$0] }
    }

    private func dedupedByID(_ nodes: [CrateNode]) -> [CrateNode] {
        var seen = Set<String>()
        var result: [CrateNode] = []
        for node in nodes where seen.insert(node.id).inserted {
            result.append(node)
        }
        return result
    }

    private func hideOnDisk(_ node: CrateNode) throws {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw SeratoPathRewriter.RewriteError.seratoIsRunning
        }

        let subcratesDirectory = libraryService.subcratesDirectory
        let smartCratesDirectory = SeratoLibraryLocator.smartCratesDirectory(in: libraryService.libraryDirectory)
        let hiddenRoot = libraryService.libraryDirectory.appendingPathComponent(Self.hiddenRootFolderName, isDirectory: true)
        let hiddenSubcrates = hiddenRoot.appendingPathComponent(Self.hiddenSubcratesFolderName, isDirectory: true)
        let hiddenSmartCrates = hiddenRoot.appendingPathComponent(Self.hiddenSmartCratesFolderName, isDirectory: true)

        try FileManager.default.createDirectory(at: hiddenSubcrates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenSmartCrates, withIntermediateDirectories: true)

        let regular = crateHierarchy.fileURLs(startingWith: node.pathComponents)
        let smart = smartCrateHierarchy.fileURLs(startingWith: node.pathComponents)
        let scannedRegular = activeCrateFiles(
            in: subcratesDirectory,
            startingWith: node.pathComponents
        )
        let scannedSmart = activeCrateFiles(
            in: smartCratesDirectory,
            startingWith: node.pathComponents
        )
        let urls = Array(Set(regular + smart + scannedRegular + scannedSmart))

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let destination: URL?
            if let relative = relativePath(of: url, to: subcratesDirectory) {
                destination = hiddenSubcrates.appendingPathComponent(relative)
            } else if let relative = relativePath(of: url, to: smartCratesDirectory) {
                destination = hiddenSmartCrates.appendingPathComponent(relative)
            } else {
                destination = nil
            }

            guard let destination else { continue }

            try SeratoBackupBeforeWrite.snapshot(of: url)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    private func unhideOnDisk(_ node: CrateNode) throws {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw SeratoPathRewriter.RewriteError.seratoIsRunning
        }

        let subcratesDirectory = libraryService.subcratesDirectory
        let smartCratesDirectory = SeratoLibraryLocator.smartCratesDirectory(in: libraryService.libraryDirectory)
        let hiddenRoot = libraryService.libraryDirectory.appendingPathComponent(Self.hiddenRootFolderName, isDirectory: true)
        let hiddenSubcrates = hiddenRoot.appendingPathComponent(Self.hiddenSubcratesFolderName, isDirectory: true)
        let hiddenSmartCrates = hiddenRoot.appendingPathComponent(Self.hiddenSmartCratesFolderName, isDirectory: true)

        let subcrateMoves = hiddenCrateMoves(
            from: hiddenSubcrates,
            to: subcratesDirectory,
            startingWith: node.pathComponents
        )
        let smartCrateMoves = hiddenCrateMoves(
            from: hiddenSmartCrates,
            to: smartCratesDirectory,
            startingWith: node.pathComponents
        )

        for (sourceURL, restoredURL) in subcrateMoves + smartCrateMoves {
            if FileManager.default.fileExists(atPath: restoredURL.path) {
                continue
            }
            try FileManager.default.createDirectory(at: restoredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: sourceURL, to: restoredURL)
        }

        // Backward compatibility for previously hidden files from the
        // extension-based strategy.
        let legacySubcrates = legacyHiddenCrateFiles(
            in: subcratesDirectory,
            startingWith: node.pathComponents
        )
        let legacySmartCrates = legacyHiddenCrateFiles(
            in: smartCratesDirectory,
            startingWith: node.pathComponents
        )
        for hiddenURL in legacySubcrates + legacySmartCrates {
            let restoredURL = hiddenURL.deletingPathExtension()
            if FileManager.default.fileExists(atPath: restoredURL.path) {
                continue
            }
            try FileManager.default.moveItem(at: hiddenURL, to: restoredURL)
        }
    }

    private func hiddenCrateMoves(from hiddenBase: URL, to restoreBase: URL, startingWith pathComponents: [String]) -> [(URL, URL)] {
        guard FileManager.default.fileExists(atPath: hiddenBase.path),
              let enumerator = FileManager.default.enumerator(
                at: hiddenBase,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [(URL, URL)] = []

        for case let sourceURL as URL in enumerator {
            let ext = sourceURL.pathExtension.lowercased()
            guard ext == "crate" || ext == "scrate" else { continue }

            let restoredURL: URL
            if let relative = relativePath(of: sourceURL, to: hiddenBase) {
                restoredURL = restoreBase.appendingPathComponent(relative)
            } else {
                continue
            }

            var directoryComponents = restoredURL
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            let restoreBaseComponents = restoreBase.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if directoryComponents.starts(with: restoreBaseComponents) {
                directoryComponents.removeFirst(restoreBaseComponents.count)
            }

            let baseName = restoredURL.deletingPathExtension().lastPathComponent
            let fullPathComponents = directoryComponents + Crate.pathComponents(forCrateFileNamed: baseName)
            if fullPathComponents.starts(with: pathComponents) {
                results.append((sourceURL, restoredURL))
            }
        }

        // keep deterministic order for predictable behavior
        return results.sorted { $0.0.path < $1.0.path }
    }

    private func activeCrateFiles(in baseDirectory: URL, startingWith pathComponents: [String]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let baseComponents = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var results: [URL] = []

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "crate" || ext == "scrate" else { continue }

            var directoryComponents = url
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            if directoryComponents.starts(with: baseComponents) {
                directoryComponents.removeFirst(baseComponents.count)
            } else {
                directoryComponents = []
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            let fullPathComponents = directoryComponents + Crate.pathComponents(forCrateFileNamed: baseName)
            if fullPathComponents.starts(with: pathComponents) {
                results.append(url)
            }
        }

        return results
    }

    private func handleTrackDrop(_ providers: [NSItemProvider], onto node: CrateNode) -> Bool {
        guard let regularNode = regularNodesByID[node.id],
              let targetCrate = regularNode.crate,
              targetCrate.fileURL?.pathExtension.lowercased() == "crate" else {
            return false
        }

        let plainTextProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !plainTextProviders.isEmpty else {
            return false
        }

        let accumulator = DroppedPathAccumulator()
        let group = DispatchGroup()

        for provider in plainTextProviders {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let value = String(data: data, encoding: .utf8) else { return }
                let decoded = TrackDragPayload.decodeMany(value)
                guard !decoded.isEmpty else { return }
                accumulator.append(contentsOf: decoded)
            }
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            let uniqueDropped = accumulator.snapshot().filter { seen.insert($0).inserted }
            guard !uniqueDropped.isEmpty else { return }

            do {
                guard let fileURL = targetCrate.fileURL else { return }
                let latestCrate = try SeratoCrateParser.parseCrate(at: fileURL)
                _ = try SeratoCrateEditor.rewriteTrackPaths(
                    in: latestCrate,
                    to: latestCrate.trackPaths + uniqueDropped
                )
                onCratesChanged()
            } catch {
                dropErrorMessage = error.localizedDescription
            }
        }

        return true
    }

    private func legacyHiddenCrateFiles(in baseDirectory: URL, startingWith pathComponents: [String]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        let baseComponents = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        for case let url as URL in enumerator {
            guard url.pathExtension == "seratotoolshidden" else { continue }
            let restoredURL = url.deletingPathExtension()
            let ext = restoredURL.pathExtension.lowercased()
            guard ext == "crate" || ext == "scrate" else { continue }

            var directoryComponents = restoredURL
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            if directoryComponents.starts(with: baseComponents) {
                directoryComponents.removeFirst(baseComponents.count)
            } else {
                directoryComponents = []
            }

            let baseName = restoredURL.deletingPathExtension().lastPathComponent
            let fullPathComponents = directoryComponents + Crate.pathComponents(forCrateFileNamed: baseName)
            if fullPathComponents.starts(with: pathComponents) {
                results.append(url)
            }
        }
        return results
    }

    private func relativePath(of url: URL, to base: URL) -> String? {
        let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
        let urlPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard urlPath.hasPrefix(basePath) else { return nil }
        var relative = String(urlPath.dropFirst(basePath.count))
        while relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.isEmpty ? nil : relative
    }


private final class DroppedPathAccumulator: @unchecked Sendable {
    private var paths: [String] = []
    private let lock = NSLock()

    func append(contentsOf newValues: [String]) {
        lock.lock()
        paths.append(contentsOf: newValues)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let copy = paths
        lock.unlock()
        return copy
    }
}
    private func smartBadgeKind(for node: CrateNode) -> SmartBadgeKind? {
        if smartNodesByID[node.id] != nil {
            return .direct
        }
        // Any strict path-prefix of a visible smart node exists in the smart
        // tree itself (CrateHierarchy synthesizes intermediate folders), so a
        // node absent from `smartNodesByID` can't have smart descendants —
        // no O(n) scan over every smart node per rendered row needed.
        return nil
    }
}

private enum SmartBadgeKind {
    case direct
    case containsSmartDescendant

    var label: String {
        switch self {
        case .direct:
            return "SMART"
        case .containsSmartDescendant:
            return "SMART+"
        }
    }

    var helpText: String {
        switch self {
        case .direct:
            return "Smart crate"
        case .containsSmartDescendant:
            return "Contains smart subcrates"
        }
    }

    var color: Color {
        switch self {
        case .direct:
            return Color(red: 0.10, green: 0.43, blue: 0.89)
        case .containsSmartDescendant:
            return Color(red: 0.23, green: 0.53, blue: 0.92)
        }
    }
}

private extension CrateNode {
    var outlineChildren: [CrateNode]? { children.isEmpty ? nil : children }
}
