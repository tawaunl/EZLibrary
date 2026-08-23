// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
@testable import EZLibraryCore

@MainActor
private func makeIgnoreStore() -> (store: DuplicateIgnoreStore, defaults: UserDefaults) {
    let defaults = TestDefaults.inMemory()
    return (DuplicateIgnoreStore(userDefaults: defaults), defaults)
}

@Test @MainActor func ignoringAGroupMarksItIgnored() {
    let (store, _) = makeIgnoreStore()
    #expect(!store.isGroupIgnored("artist|title|original"))
    store.ignoreGroup("artist|title|original")
    #expect(store.isGroupIgnored("artist|title|original"))
}

@Test @MainActor func restoringAGroupReversesIgnore() {
    let (store, _) = makeIgnoreStore()
    store.ignoreGroup("artist|title|original")
    store.restoreGroup("artist|title|original")
    #expect(!store.isGroupIgnored("artist|title|original"))
}

@Test @MainActor func ignoringATrackMarksItIgnored() {
    let (store, _) = makeIgnoreStore()
    let path = "Music/Song.mp3"
    #expect(!store.isTrackIgnored(path))
    store.ignoreTrack(path)
    #expect(store.isTrackIgnored(path))
    store.restoreTrack(path)
    #expect(!store.isTrackIgnored(path))
}

@Test @MainActor func restoreAllClearsGroupsAndTracks() {
    let (store, _) = makeIgnoreStore()
    store.ignoreGroup("g1")
    store.ignoreTrack("t1")
    store.restoreAll()
    #expect(store.ignoredGroupIDs.isEmpty)
    #expect(store.ignoredTrackPaths.isEmpty)
}

@Test @MainActor func ignoresPersistAcrossInstancesWithSameDefaults() {
    let (store, defaults) = makeIgnoreStore()
    store.ignoreGroup("g1")
    store.ignoreTrack("t1")

    let reloaded = DuplicateIgnoreStore(userDefaults: defaults)
    #expect(reloaded.isGroupIgnored("g1"))
    #expect(reloaded.isTrackIgnored("t1"))
}
