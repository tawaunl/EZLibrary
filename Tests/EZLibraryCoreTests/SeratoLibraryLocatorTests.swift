import Testing
import Foundation
@testable import EZLibraryCore

@Test func databaseFileIsInsideLibraryDirectory() {
    let library = URL(fileURLWithPath: "/tmp/_Serato_")
    let database = SeratoLibraryLocator.databaseFile(in: library)
    #expect(database.lastPathComponent == "database V2")
    #expect(database.deletingLastPathComponent() == library)
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
