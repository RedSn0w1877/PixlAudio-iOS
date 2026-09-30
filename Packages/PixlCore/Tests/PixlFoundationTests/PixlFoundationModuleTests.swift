import Foundation
import Testing
@testable import PixlFoundation

@Suite("PixlFoundation module")
struct PixlFoundationModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlFoundationModule.name == "PixlFoundation")
        #expect(!PixlFoundationModule.dependencies.contains(PixlFoundationModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlFoundation"))
    }
}
