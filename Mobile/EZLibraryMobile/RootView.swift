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
import UniformTypeIdentifiers
import EZLibrarySnapshotKit

struct RootView: View {
    @Environment(SnapshotStore.self) private var store
    @State private var isPickingFolder = false

    var body: some View {
        Group {
            switch store.state {
            case .needsFolder:
                WelcomeView { isPickingFolder = true }
            case .loading:
                ProgressView("Reading your library…")
            case let .loaded(library):
                LibraryBrowser(library: library) { isPickingFolder = true }
            case let .failed(message):
                FailureView(message: message) { isPickingFolder = true }
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case let .success(url):
                store.use(folder: url)
            case let .failure(error):
                print("Folder selection failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Shown before a folder has ever been chosen.
private struct WelcomeView: View {
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("Your crates, offline")
                .font(.title.weight(.semibold))

            Text("""
                On your Mac, open EZLibrary and export a snapshot from Offline Sync. \
                Then pick that \(SnapshotFolder.defaultFolderName) folder here — usually in \
                iCloud Drive — and your library travels with you.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Choose Folder", action: chooseFolder)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct FailureView: View {
    let message: String
    let chooseFolder: () -> Void
    @Environment(SnapshotStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button("Try Again") { store.reload() }
                Button("Choose Another Folder", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
