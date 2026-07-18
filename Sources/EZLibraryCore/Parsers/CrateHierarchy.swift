import Foundation

/// Builds the browsable parent/child crate tree from a flat list of
/// `Crate` values. Pure function, no I/O — assumes each `Crate`'s
/// `pathComponents` already fully reflects however it's nested on disk
/// (both the `≫≫`-delimited filename convention and real subdirectory
/// nesting are normalized into `pathComponents` upstream, in
/// `LibraryService`, before this ever runs).
public enum CrateHierarchy {
    public static func build(from crates: [Crate]) -> [CrateNode] {
        let root = Builder(pathComponents: [])
        for crate in crates where !crate.pathComponents.isEmpty {
            var node = root
            var prefix: [String] = []
            for component in crate.pathComponents {
                prefix.append(component)
                if let existing = node.childrenByName[component] {
                    node = existing
                } else {
                    let child = Builder(pathComponents: prefix)
                    node.childrenByName[component] = child
                    node.orderedChildNames.append(component)
                    node = child
                }
            }
            node.crate = crate
        }
        return root.freeze().children
    }

    private final class Builder {
        let pathComponents: [String]
        var crate: Crate?
        var childrenByName: [String: Builder] = [:]
        var orderedChildNames: [String] = []

        init(pathComponents: [String]) {
            self.pathComponents = pathComponents
        }

        func freeze() -> CrateNode {
            let children = orderedChildNames
                .compactMap { childrenByName[$0] }
                .sorted { $0.pathComponents.last! < $1.pathComponents.last! }
                .map { $0.freeze() }
            return CrateNode(pathComponents: pathComponents, crate: crate, children: children)
        }
    }
}
