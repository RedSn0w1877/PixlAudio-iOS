import Foundation
import Testing
@testable import PixlTags

@Suite("PixlTags module")
struct PixlTagsModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlTagsModule.name == "PixlTags")
        #expect(!PixlTagsModule.dependencies.contains(PixlTagsModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlTags"))
    }
}
