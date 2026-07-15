import Foundation

/// Owns the browsable, filtered crate tree for one section of `CrateView`
/// (regular crates or Smart Crates) — search text, hide/unhide, and delete.
///
/// `LibraryService` stays focused on "parse the library, expose flat
/// `tracks`/`crates`"; this type derives the tree/search/hide view state
/// from that, rather than growing `LibraryService` unboundedly.
@MainActor
public final class CrateHierarchyViewModel: ObservableObject {
    @Published public var searchText: String = "" {
        didSet { invalidateDerivedCaches() }
    }
    @Published private var allCrates: [Crate] = []

    /// Smart Crates are hide-only in Phase 1 (no delete-to-Trash), since
    /// deleting one could surprise a user who expects Serato to manage it
    /// via rules we don't parse.
    public let allowsDelete: Bool

    private let hiddenStore: HiddenCrateStore

    /// Derived tree state is cached and invalidated on input changes
    /// (`rebuild`, `searchText`, hide/unhide): `visibleTree` and friends are
    /// read many times per SwiftUI render pass (including once per visible
    /// row for badges), and rebuilding the whole tree on every access made
    /// the crate list lag with large libraries.
    private var cachedVisibleTree: [CrateNode]?
    private var cachedVisibleNodesByID: [String: CrateNode]?
    private var cachedHiddenNodes: [CrateNode]?

    public init(hiddenStore: HiddenCrateStore, allowsDelete: Bool = true) {
        self.hiddenStore = hiddenStore
        self.allowsDelete = allowsDelete
    }

    public func rebuild(from crates: [Crate]) {
        allCrates = crates
        invalidateDerivedCaches()
    }

    public var visibleTree: [CrateNode] {
        if let cachedVisibleTree {
            return cachedVisibleTree
        }
        let tree = filtered(CrateHierarchy.build(from: allCrates))
        cachedVisibleTree = tree
        return tree
    }

    /// Every node in `visibleTree` (including synthesized folders), keyed by
    /// `CrateNode.id`, for O(1) lookups from row-level view code.
    public var visibleNodesByID: [String: CrateNode] {
        if let cachedVisibleNodesByID {
            return cachedVisibleNodesByID
        }
        var map: [String: CrateNode] = [:]
        func walk(_ nodes: [CrateNode]) {
            for node in nodes {
                map[node.id] = node
                walk(node.children)
            }
        }
        walk(visibleTree)
        cachedVisibleNodesByID = map
        return map
    }

    public func isHidden(_ node: CrateNode) -> Bool {
        hiddenStore.isHidden(node)
    }

    public func hide(_ node: CrateNode) {
        hiddenStore.hide(node)
        invalidateDerivedCaches()
        objectWillChange.send()
    }

    public func unhide(_ node: CrateNode) {
        hiddenStore.unhide(node)
        invalidateDerivedCaches()
        objectWillChange.send()
    }

    /// Every currently-hidden node anywhere in the full (unfiltered) tree,
    /// for the "Hidden (n)" one-click-unhide disclosure.
    public var hiddenNodes: [CrateNode] {
        if let cachedHiddenNodes {
            return cachedHiddenNodes
        }
        var result: [CrateNode] = hiddenStore.hiddenIDs
            .map { CrateNode(pathComponents: $0.split(separator: "/").map(String.init)) }
        var seenIDs = Set(result.map(\.id))

        // Also include currently-loaded hidden descendants for context when
        // a broad parent is hidden.
        func walk(_ nodes: [CrateNode]) {
            for node in nodes {
                if hiddenStore.isHidden(node), seenIDs.insert(node.id).inserted {
                    result.append(node)
                }
                walk(node.children)
            }
        }
        walk(CrateHierarchy.build(from: allCrates))
        let sorted = result.sorted { $0.id < $1.id }
        cachedHiddenNodes = sorted
        return sorted
    }

    private func invalidateDerivedCaches() {
        cachedVisibleTree = nil
        cachedVisibleNodesByID = nil
        cachedHiddenNodes = nil
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
