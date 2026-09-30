import Foundation
import Testing
@testable import PixlAudioCore

@Suite("PixlAudioCore module")
struct PixlAudioCoreModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlAudioCoreModule.name == "PixlAudioCore")
        #expect(!PixlAudioCoreModule.dependencies.contains(PixlAudioCoreModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlAudioCore"))
    }
}
