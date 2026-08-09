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
import EZLibraryCore

/// Shared plumbing for the track table's "Add to Crate" menu.
///
/// Both the crate detail view and the library browsers offer the same menu, so
/// the target list and the lookup back to a `Crate` live in one place.
enum CrateContextMenuSupport {
    /// Menu entries for every plain crate, alphabetised by their displayed
    /// path. Smart crates are omitted: their membership comes from rules, and
    /// a hand-added track would be discarded the next time Serato re-evaluates
    /// them.
    ///
    /// Build this once per crate change, not per body evaluation — it maps and
    /// sorts every crate in the library.
    static func targets(for crates: [Crate]) -> [TrackContextMenuActions.CrateTarget] {
        crates
            .compactMap { crate in
                guard let id = identifier(for: crate) else { return nil }
                return TrackContextMenuActions.CrateTarget(
                    id: id,
                    title: crate.pathComponents.joined(separator: " ▸ ")
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func crate(
        withID id: String,
        in crates: [Crate]
    ) -> Crate? {
        crates.first { identifier(for: $0) == id }
    }

    /// The crate file's path. `Crate.id` is a fresh UUID per parse, so it can't
    /// survive the reload that follows every membership change.
    private static func identifier(for crate: Crate) -> String? {
        crate.fileURL?.standardizedFileURL.path
    }
}
