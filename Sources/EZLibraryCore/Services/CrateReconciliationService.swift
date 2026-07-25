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

/// What a duplicate deletion would do to one crate.
public struct CratePlanChange: Sendable, Equatable {
    public let crateName: String
    public let trackPaths: [String]
    /// Deleted copies replaced in place by the copy being kept.
    public let repointedCount: Int
    /// Deleted copies simply dropped, because the kept copy was already in
    /// this crate — keeping both would duplicate the entry.
    public let removedCount: Int

    public init(crateName: String, trackPaths: [String], repointedCount: Int, removedCount: Int) {
        self.crateName = crateName
        self.trackPaths = trackPaths
        self.repointedCount = repointedCount
        self.removedCount = removedCount
    }
}

public struct CrateReconciliationPlan: Sendable {
    /// Crates needing a rewrite, keyed by crate id.
    public let changes: [UUID: CratePlanChange]
    /// Crates that would lose every track — a strong signal something is wrong
    /// with the deletion, since a duplicate's replacement should take its slot.
    public let emptiedCrateNames: [String]

    public var affectedCrateCount: Int { changes.count }
    public var totalRepointed: Int { changes.values.reduce(0) { $0 + $1.repointedCount } }
    public var totalRemoved: Int { changes.values.reduce(0) { $0 + $1.removedCount } }
    public var isEmpty: Bool { changes.isEmpty }

    public init(changes: [UUID: CratePlanChange], emptiedCrateNames: [String]) {
        self.changes = changes
        self.emptiedCrateNames = emptiedCrateNames
    }
}

/// Keeps crates intact when duplicates are deleted.
///
/// Removing a duplicate's path from every crate is not enough. If a crate
/// referenced the copy being deleted and *not* the copy being kept, stripping
/// the path silently drops that song from the crate — the crate gets shorter,
/// and a crate built entirely from now-deleted copies empties completely.
///
/// The right move is to re-point the reference: the kept copy takes the
/// deleted copy's place, in the same position, so the crate still plays the
/// same music.
public enum CrateReconciliationService {
    /// Computes crate rewrites for a deletion.
    ///
    /// - Parameters:
    ///   - crates: Every crate in the library.
    ///   - deletedPaths: Serato stored paths being removed.
    ///   - keptPathForDeleted: For each deleted path, the copy that survives
    ///     it. A deleted path with no surviving copy is simply removed.
    public static func plan(
        crates: [Crate],
        deletedPaths: Set<String>,
        keptPathForDeleted: [String: String]
    ) -> CrateReconciliationPlan {
        guard !deletedPaths.isEmpty else {
            return CrateReconciliationPlan(changes: [:], emptiedCrateNames: [])
        }

        var changes: [UUID: CratePlanChange] = [:]
        var emptied: [String] = []

        for crate in crates {
            guard crate.fileURL?.pathExtension.lowercased() == "crate" else { continue }
            guard crate.trackPaths.contains(where: { deletedPaths.contains($0) }) else { continue }

            var rewritten: [String] = []
            rewritten.reserveCapacity(crate.trackPaths.count)
            var present = Set<String>()
            var repointed = 0
            var removed = 0

            for path in crate.trackPaths {
                guard deletedPaths.contains(path) else {
                    if present.insert(path).inserted {
                        rewritten.append(path)
                    }
                    continue
                }

                // Substitute the survivor in this slot, preserving crate order.
                if let kept = keptPathForDeleted[path], !deletedPaths.contains(kept) {
                    if present.insert(kept).inserted {
                        rewritten.append(kept)
                        repointed += 1
                    } else {
                        // The kept copy is already in this crate, so the
                        // duplicate entry just goes away.
                        removed += 1
                    }
                } else {
                    removed += 1
                }
            }

            guard rewritten != crate.trackPaths else { continue }

            changes[crate.id] = CratePlanChange(
                crateName: crate.name,
                trackPaths: rewritten,
                repointedCount: repointed,
                removedCount: removed
            )

            if rewritten.isEmpty && !crate.trackPaths.isEmpty {
                emptied.append(crate.name)
            }
        }

        return CrateReconciliationPlan(changes: changes, emptiedCrateNames: emptied)
    }

    /// Applies a plan, rewriting each affected crate file.
    ///
    /// Returns the crates that were rewritten, so callers can refresh state.
    @discardableResult
    public static func apply(
        _ plan: CrateReconciliationPlan,
        to crates: [Crate]
    ) throws -> [Crate] {
        guard !plan.isEmpty else { return [] }

        var updated: [Crate] = []
        for crate in crates {
            guard let change = plan.changes[crate.id] else { continue }
            updated.append(try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: change.trackPaths))
        }
        return updated
    }

    /// Human-readable summary for the deletion confirmation and result message.
    public static func summary(for plan: CrateReconciliationPlan) -> String? {
        guard !plan.isEmpty else { return nil }

        var parts: [String] = []
        if plan.totalRepointed > 0 {
            parts.append("\(plan.totalRepointed) crate entr\(plan.totalRepointed == 1 ? "y" : "ies") re-pointed to the copy you're keeping")
        }
        if plan.totalRemoved > 0 {
            parts.append("\(plan.totalRemoved) redundant entr\(plan.totalRemoved == 1 ? "y" : "ies") removed")
        }
        if parts.isEmpty { return nil }

        var text = parts.joined(separator: ", ")
        text += " across \(plan.affectedCrateCount) crate\(plan.affectedCrateCount == 1 ? "" : "s")"
        if !plan.emptiedCrateNames.isEmpty {
            text += ". Warning — these crates would be left empty: \(plan.emptiedCrateNames.joined(separator: ", "))"
        }
        return text + "."
    }
}
