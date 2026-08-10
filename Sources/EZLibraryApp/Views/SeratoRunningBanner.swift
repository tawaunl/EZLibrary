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

/// Shown for as long as Serato is running, because every library write is
/// refused while it is. Says so up front instead of letting each action fail
/// on its own.
struct SeratoRunningBanner: View {
    @ObservedObject var model: SeratoRunningModel

    var body: some View {
        if model.isSeratoRunning {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Serato is running — the library is read-only")
                        .font(.headline)
                    Text("Serato rewrites its library and crates from memory when it quits, so anything changed now would be reverted. Quit Serato DJ to edit tags, sync folders, or change crates. Browsing and searching still work.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Check Again") {
                    model.refresh()
                }
                .help("Re-check whether Serato is still running.")
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) {
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Serato is running. The library is read-only until Serato quits.")
        }
    }
}
