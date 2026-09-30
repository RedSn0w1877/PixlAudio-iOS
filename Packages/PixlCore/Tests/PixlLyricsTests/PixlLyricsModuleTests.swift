import Foundation
import Testing
@testable import PixlLyrics

@Suite("PixlLyrics module")
struct PixlLyricsModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlLyricsModule.name == "PixlLyrics")
        #expect(!PixlLyricsModule.dependencies.contains(PixlLyricsModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlLyrics"))
    }
}
