import Foundation
import Testing
@testable import PixlLibrary

@Suite("PixlLibrary module")
struct PixlLibraryModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlLibraryModule.name == "PixlLibrary")
        #expect(!PixlLibraryModule.dependencies.contains(PixlLibraryModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlLibrary"))
    }
}
