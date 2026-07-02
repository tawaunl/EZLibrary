import Foundation

/// Owns the browsable, filtered crate tree for one section of `CrateView`
/// (regular crates or Smart Crates) — search text, hide/unhide, and delete.
///
/// `LibraryService` stays focused on "parse the library, expose flat
/// `tracks`/`crates`"; this type derives the tree/search/hide view state
/// from that, rather than growing `LibraryService` unboundedly.
@MainActor
public final class CrateHierarchyViewModel: ObservableObject {
    @Published public var searchText: String = ""
    @Published private var allCrates: [Crate] = []

    /// Smart Crates are hide-only in Phase 1 (no delete-to-Trash), since
    /// deleting one could surprise a user who expects Serato to manage it
    /// via rules we don't parse.
    public let allowsDelete: Bool

    private let hiddenStore: HiddenCrateStore

    public init(hiddenStore: HiddenCrateStore, allowsDelete: Bool = true) {
        self.hiddenStore = hiddenStore
        self.allowsDelete = allowsDelete
    }

    public func rebuild(from crates: [Crate]) {
        allCrates = crates
    }

    public var visibleTree: [CrateNode] {
        filtered(CrateHierarchy.build(from: allCrates))
    }

    public func isHidden(_ node: CrateNode) -> Bool {
        hiddenStore.isHidden(node)
    }

    public func hide(_ node: CrateNode) {
        hiddenStore.hide(node)
        objectWillChange.send()
    }

    public func unhide(_ node: CrateNode) {
        hiddenStore.unhide(node)
        objectWillChange.send()
    }

    /// Every currently-hidden node anywhere in the full (unfiltered) tree,
    /// for the "Hidden (n)" one-click-unhide disclosure.
    public var hiddenNodes: [CrateNode] {
        var result: [CrateNode] = hiddenStore.hiddenIDs
            .map { CrateNode(pathComponents: $0.split(separator: "/").map(String.init)) }

        // Also include currently-loaded hidden descendants for context when
        // a broad parent is hidden.
        func walk(_ nodes: [CrateNode]) {
            for node in nodes {
                if hiddenStore.isHidden(node), !result.contains(where: { $0.id == node.id }) {
                    result.append(node)
                }
                walk(node.children)
            }
        }
        walk(CrateHierarchy.build(from: allCrates))
        return result.sorted { $0.id < $1.id }
    }

    /// Real crate files whose crate paths start with `pathComponents`.
    public func fileURLs(startingWith pathComponents: [String]) -> [URL] {
        allCrates
            .filter { $0.pathComponents.starts(with: pathComponents) }
            .compactMap(\.fileURL)
    }

    /// For a node with its own `.crate` file, trashes just that file. For a
    /// synthesized folder-only node, recursively trashes every descendant's
    /// real file individually (confirmed behavior — `FileManager.trashItem`
    /// can't trash a "virtual" folder that isn't a real filesystem entry).
    /// Returns the number of files trashed, so callers can show it in a
    /// confirmation dialog before calling this.
    @discardableResult
    public func delete(_ node: CrateNode) throws -> Int {
        guard allowsDelete else { return 0 }
        var trashedCount = 0
        for url in fileURLs(under: node) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            trashedCount += 1
        }
        return trashedCount
    }

    /// Count of real `.crate`/`.scrate` files a delete of `node` would
    /// affect — for the confirmation dialog to state up front.
    public func deletionCount(for node: CrateNode) -> Int {
        fileURLs(under: node).count
    }

    private func fileURLs(under node: CrateNode) -> [URL] {
        var urls: [URL] = []
        if let fileURL = node.crate?.fileURL {
            urls.append(fileURL)
        }
        for child in node.children {
            urls.append(contentsOf: fileURLs(under: child))
        }
        return urls
    }

    private func filtered(_ nodes: [CrateNode]) -> [CrateNode] {
        nodes.compactMap { node in
            if hiddenStore.isHidden(node) { return nil }
            var node = node
            node.children = filtered(node.children)
            if searchText.isEmpty { return node }
            let matchesSelf = node.name.localizedCaseInsensitiveContains(searchText)
            if matchesSelf || !node.children.isEmpty {
                return node
            }
            return nil
        }
    }
}
