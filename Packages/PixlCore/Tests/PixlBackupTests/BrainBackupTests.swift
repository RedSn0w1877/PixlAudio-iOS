import Foundation
import PixlFoundation
import Testing
@testable import PixlBackup

/// The brain's backup module (docs/brain-spec.md, 12.2, 13.2; Android's `BrainBackupFormatTest`): the salt, the taste changes and the
/// exclusions, in the payload Android writes. Pure text in and out.
@Suite struct BrainBackupTests {
    let payload = BrainBackupPayload(
        salt: "-7345987123456789", adjustments: "{\"items\":[{\"label\":\"A&B <x>\"}]}",
        feedback: [BrainBackupFeedbackRow(id: 16, kind: 2, targetKind: 1, targetId: 99, createdAtMs: 1_785_000_000_000),
                   BrainBackupFeedbackRow(id: 24, kind: 2, targetKind: 4, targetId: 0, createdAtMs: 1_785_000_100_000, undoneAtMs: 1_785_000_200_000)])

    @Test func theModuleRoundTrips() throws {
        let text = BrainBackupModule.export(payload)
        #expect(BrainBackupModule.decode(text) == payload)
        #expect(try BrainBackupModule.restore(payload: text) == payload)
        // The payload is Android's: its format tag, and a feedback row with the field names Android reads.
        #expect(text.contains("\"format\": \"brain-backup-v1\""))
        #expect(text.contains("\"targetKind\": 4"))
    }

    @Test func aNullSaltAndNoRowsAreAPayload() {
        let empty = BrainBackupPayload(salt: nil, adjustments: "", feedback: [])
        let text = BrainBackupModule.export(empty)
        #expect(!text.contains("\"salt\""))
        #expect(BrainBackupModule.decode(text) == empty)
    }

    @Test func readsWhatAndroidWrites() {
        // `BrainBackupFormat.encode` with Gson: a salt as text, the adjustments text, rows with `undoneAtMs` absent or null.
        let android = """
        {"format":"brain-backup-v1","salt":"42","adjustments":"","feedback":[{"id":8,"kind":2,"targetKind":1,"targetId":7,"createdAtMs":5},\
        {"id":9,"kind":2,"targetKind":1,"targetId":8,"createdAtMs":6,"undoneAtMs":null}]}
        """
        let parsed = BrainBackupModule.decode(android)
        #expect(parsed?.salt == "42")
        #expect(parsed?.feedback.count == 2)
        #expect(parsed?.feedback.last?.undoneAtMs == nil)
    }

    @Test func anythingThatIsNotAWellFormedBrainBackupIsRefused() {
        let bad = ["", "null", "[]", "{}", "{\"format\":\"other\",\"feedback\":[]}", "{\"format\":\"brain-backup-v1\"}",
                   "{\"format\":\"brain-backup-v1\",\"feedback\":{}}",
                   "{\"format\":\"brain-backup-v1\",\"salt\":\"not a number\",\"feedback\":[]}",
                   "{\"format\":\"brain-backup-v1\",\"feedback\":[{\"id\":1,\"kind\":2,\"targetKind\":1,\"targetId\":1,\"createdAtMs\":-1}]}",
                   "{\"format\":\"brain-backup-v1\",\"feedback\":[{\"id\":1}]}", "not json"]
        for text in bad { #expect(BrainBackupModule.decode(text) == nil, "\(text.prefix(60))") }
        #expect(throws: BackupError.self) { try BrainBackupModule.restore(payload: "{}") }
    }

    @Test func aPayloadWithMoreRowsThanTheLimitIsRefused() {
        var rows = ""
        for i in 0...BrainBackupModule.maxFeedback {
            rows += (i == 0 ? "" : ",") + "{\"id\":\(i),\"kind\":2,\"targetKind\":1,\"targetId\":1,\"createdAtMs\":1}"
        }
        #expect(BrainBackupModule.decode("{\"format\":\"brain-backup-v1\",\"feedback\":[\(rows)]}") == nil)
    }

    @Test func theValidatorAcceptsTheObjectAndRefusesOtherShapes() throws {
        let good = try ModuleSchemaValidator.validate(.brain, payload: BrainBackupModule.export(payload))
        #expect(good == .valid)
        let array = try ModuleSchemaValidator.validate(.brain, payload: "[]")
        #expect(array != .valid)
        let wrong = try ModuleSchemaValidator.validate(.brain, payload: "{\"format\":\"x\"}")
        #expect(wrong != .valid)
    }
}
