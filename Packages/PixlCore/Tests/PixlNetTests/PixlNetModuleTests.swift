import Foundation
import Testing
@testable import PixlNet

@Suite("PixlNet module")
struct PixlNetModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlNetModule.name == "PixlNet")
        #expect(!PixlNetModule.dependencies.contains(PixlNetModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlNet"))
    }
}
