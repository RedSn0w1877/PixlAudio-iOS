import Foundation
import Testing
@testable import PixlBackup

@Suite("PixlBackup module")
struct PixlBackupModuleTests {
    @Test func moduleIsLinked() {
        #expect(PixlBackupModule.name == "PixlBackup")
        #expect(!PixlBackupModule.dependencies.contains(PixlBackupModule.name))
    }

    @Test func fixturesAreBundled() throws {
        let url = try #require(Bundle.module.url(forResource: "README", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("PixlBackup"))
    }
}
