import Testing
import Foundation
@testable import EZLibraryCore

@Test func databaseFileIsInsideLibraryDirectory() {
    let library = URL(fileURLWithPath: "/tmp/_Serato_")
    let database = SeratoLibraryLocator.databaseFile(in: library)
    #expect(database.lastPathComponent == "database V2")
    // Compare paths, not URLs: `deletingLastPathComponent()` appends a
    // trailing slash (file:///tmp/_Serato_/), so a raw URL `==` against the
    // slash-less library URL fails even though they're the same directory.
    #expect(database.deletingLastPathComponent().path == library.path)
}

@Test func subcrateFilesRecurseIntoRealSubdirectories() throws {
    // Regression test: the real library has `Subcrates/Serato Stems/Stems.crate`,
    // nested via an actual subdirectory rather than the `≫≫` filename
    // convention. A non-recursive enumeration misses it entirely.
    let library = Bundle.module
        .url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
    let entries = SeratoLibraryLocator.subcrateFiles(in: library)
    let stems = try #require(entries.first { $0.url.lastPathComponent == "Stems.crate" })
    #expect(stems.directoryComponents == ["Serato Stems"])
}

@Test func smartCrateFilesAreFoundUnderSmartCratesDirectory() {
    let library = Bundle.module
        .url(forResource: "Fixtures/RealLibrarySample", withExtension: nil)!
    let entries = SeratoLibraryLocator.smartCrateFiles(in: library)
    #expect(entries.contains { $0.url.lastPathComponent == "Latest Imported.scrate" })
}
