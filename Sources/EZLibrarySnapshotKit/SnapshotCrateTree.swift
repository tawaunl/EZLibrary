// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation

/// One node in the browsable crate tree built from a snapshot.
///
/// Distinct from `SnapshotCrate` (which matches exactly one crate file): a
/// node may be a synthesized folder with no crate of its own, needed when an
/// intermediate path segment exists only because deeper crates reference it —
/// e.g. "ALL GENRES" when the library only has "ALL GENRES ≫≫ Disco".
public struct SnapshotCrateNode: Identifiable, Hashable, Sendable {
    /// Stable across reloads and devices: the joined path components. A bare
    /// name would collide across different parents.
    public var id: String { pathComponents.joined(separator: "/") }

    public let pathComponents: [String]
    public var crate: SnapshotCrate?
    public var children: [SnapshotCrateNode]

    public var name: String { pathComponents.last ?? "" }

    /// Tracks listed directly in this node's own crate. A synthesized folder
    /// has none of its own — see `allTrackPaths` for the subtree.
    public var trackPaths: [String] { crate?.trackPaths ?? [] }

    public init(
        pathComponents: [String],
        crate: SnapshotCrate? = nil,
        children: [SnapshotCrateNode] = []
    ) {
        self.pathComponents = pathComponents
        self.crate = crate
        self.children = children
    }

    /// Every distinct track path in this node and everything nested under it,
    /// in first-seen order.
    ///
    /// Deduplicated because the same track can legitimately sit in a parent
    /// crate and a child of it, and showing it twice in one list would read
    /// as a bug.
    public var allTrackPaths: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        appendTrackPaths(into: &ordered, seen: &seen)
        return ordered
    }

    private func appendTrackPaths(into ordered: inout [String], seen: inout Set<String>) {
        for path in trackPaths where seen.insert(path).inserted {
            ordered.append(path)
        }
        for child in children {
            child.appendTrackPaths(into: &ordered, seen: &seen)
        }
    }
}

/// Builds the browsable parent/child crate tree from a snapshot's flat crate
/// list.
///
/// Pure function, no I/O. Mirrors `CrateHierarchy` on the Mac so both sides
/// nest and order crates identically — the same crates in the same order,
/// whichever device is showing them.
public enum SnapshotCrateTree {
    public static func build(from crates: [SnapshotCrate]) -> [SnapshotCrateNode] {
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
        var crate: SnapshotCrate?
        var childrenByName: [String: Builder] = [:]
        var orderedChildNames: [String] = []

        init(pathComponents: [String]) {
            self.pathComponents = pathComponents
        }

        func freeze() -> SnapshotCrateNode {
            let children = orderedChildNames
                .compactMap { childrenByName[$0] }
                .sorted { ($0.pathComponents.last ?? "") < ($1.pathComponents.last ?? "") }
                .map { $0.freeze() }
            return SnapshotCrateNode(pathComponents: pathComponents, crate: crate, children: children)
        }
    }
}
