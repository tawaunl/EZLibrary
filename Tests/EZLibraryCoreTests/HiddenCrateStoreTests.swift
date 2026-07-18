import Testing
import Foundation
@testable import EZLibraryCore

@MainActor
private func makeStore() -> HiddenCrateStore {
    let suiteName = "com.seratotools.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return HiddenCrateStore(userDefaults: defaults)
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
    let suiteName = "com.seratotools.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let node = CrateNode(pathComponents: ["Recorded"])

    let first = HiddenCrateStore(userDefaults: defaults)
    first.hide(node)

    let second = HiddenCrateStore(userDefaults: defaults)
    #expect(second.isHidden(node))
}
