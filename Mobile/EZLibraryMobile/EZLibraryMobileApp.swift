// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI

@main
struct EZLibraryMobileApp: App {
    @State private var store = SnapshotStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { store.restore() }
        }
    }
}
