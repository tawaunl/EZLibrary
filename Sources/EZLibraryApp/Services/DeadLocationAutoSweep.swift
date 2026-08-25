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

/// Prunes provably-dead disconnected locations from Serato's `master.sqlite`
/// as part of the bulk move/rename workflow, so reorganizing files never
/// leaves "cannot be located" clutter behind.
///
/// Runs off the main actor, only when enabled, and only when Serato is closed
/// (the sweep refuses otherwise). Failures are swallowed: this is opportunistic
/// housekeeping that must never turn a successful move into a visible error.
enum DeadLocationAutoSweep {
    @discardableResult
    static func runIfEnabled(
        userDefaults: UserDefaults = .standard
    ) async -> SeratoDeadLocationSweeper.Summary {
        guard SeratoFeatureFlags.isAutoRemoveDeadLocationsEnabled(userDefaults: userDefaults) else {
            return .none
        }
        return await Task.detached(priority: .utility) {
            (try? SeratoDeadLocationSweeper.sweep()) ?? .none
        }.value
    }
}
