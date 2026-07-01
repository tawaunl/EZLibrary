import Testing
import Foundation
@testable import SeratoToolsCore

@Test func databaseFileIsInsideLibraryDirectory() {
    let library = URL(fileURLWithPath: "/tmp/_Serato_")
    let database = SeratoLibraryLocator.databaseFile(in: library)
    #expect(database.lastPathComponent == "database V2")
    #expect(database.deletingLastPathComponent() == library)
}
