import Foundation
import Testing
@testable import PixlModel

@Suite("PixlModel module")
struct PixlModelModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlModelModule.name == "PixlModel")
        #expect(!PixlModelModule.dependencies.contains(PixlModelModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlModel"))
    }
}
