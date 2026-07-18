import Testing
@testable import EZLibraryCore

@Test func buildsFlatTreeForUnnestedCrates() {
    let crates = [
        Crate(pathComponents: ["Recorded"]),
        Crate(pathComponents: ["Pride mix"])
    ]
    let tree = CrateHierarchy.build(from: crates)
    #expect(tree.map(\.name) == ["Pride mix", "Recorded"])
    #expect(tree.allSatisfy { $0.children.isEmpty })
}

@Test func synthesizesFolderNodeForMissingIntermediateCrate() {
    // Only "ALL GENRES≫≫Disco.crate" exists on disk — no bare
    // "ALL GENRES.crate" — so "ALL GENRES" must be a synthesized
    // folder-only node with `crate == nil`.
    let crates = [Crate(pathComponents: ["ALL GENRES", "Disco"])]
    let tree = CrateHierarchy.build(from: crates)

    #expect(tree.count == 1)
    let allGenres = tree[0]
    #expect(allGenres.name == "ALL GENRES")
    #expect(allGenres.crate == nil)
    #expect(allGenres.children.map(\.name) == ["Disco"])
    #expect(allGenres.children[0].crate != nil)
}

@Test func directoryNestedPathAlreadyFlattenedBuildsSameShapeAsDelimiterNesting() {
    // CrateHierarchy doesn't care which mechanism produced pathComponents
    // (real subdirectory vs. `≫≫` filename) — both arrive pre-flattened.
    let crates = [Crate(pathComponents: ["Serato Stems", "Stems"])]
    let tree = CrateHierarchy.build(from: crates)

    #expect(tree.count == 1)
    #expect(tree[0].name == "Serato Stems")
    #expect(tree[0].children.map(\.name) == ["Stems"])
}

@Test func realCrateWithChildrenIsBothALeafAndAParent() {
    // A crate file can exist AND have deeper nested crates underneath it
    // (e.g. "ALL GENRES.crate" plus "ALL GENRES≫≫Disco.crate").
    let crates = [
        Crate(pathComponents: ["ALL GENRES"], trackPaths: ["Music/a.mp3"]),
        Crate(pathComponents: ["ALL GENRES", "Disco"])
    ]
    let tree = CrateHierarchy.build(from: crates)

    #expect(tree.count == 1)
    #expect(tree[0].crate?.trackPaths == ["Music/a.mp3"])
    #expect(tree[0].children.map(\.name) == ["Disco"])
}
