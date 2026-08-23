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
private func makeStore() -> HiddenCrateStore {
    HiddenCrateStore(userDefaults: TestDefaults.inMemory())
}

@Test @MainActor func hidingACrateMarksItHidden() {
    let store = makeStore()
    let node = CrateNode(pathComponents: ["Recorded"])
    #expect(!store.isHidden(node))
    store.hide(node)
    #expect(store.isHidden(node))
}

@Test @MainActor func unhideReversesHide() {
    let store = makeStore()
    let node = CrateNode(pathComponents: ["Recorded"])
    store.hide(node)
    store.unhide(node)
    #expect(!store.isHidden(node))
}

@Test @MainActor func hidingAFolderHidesItsDescendants() {
    let store = makeStore()
    let parent = CrateNode(pathComponents: ["ALL GENRES"])
    let child = CrateNode(pathComponents: ["ALL GENRES", "Disco"])
    store.hide(parent)
    #expect(store.isHidden(child))
}

@Test @MainActor func sameNameUnderDifferentParentsDoesNotCollide() {
    let store = makeStore()
    let a = CrateNode(pathComponents: ["Genre A", "Recorded"])
    let b = CrateNode(pathComponents: ["Genre B", "Recorded"])
    store.hide(a)
    #expect(store.isHidden(a))
    #expect(!store.isHidden(b))
}

@Test @MainActor func persistsAcrossInstancesWithTheSameUserDefaults() {
    let defaults = TestDefaults.inMemory()
    let node = CrateNode(pathComponents: ["Recorded"])

    let first = HiddenCrateStore(userDefaults: defaults)
    first.hide(node)

    let second = HiddenCrateStore(userDefaults: defaults)
    #expect(second.isHidden(node))
}
