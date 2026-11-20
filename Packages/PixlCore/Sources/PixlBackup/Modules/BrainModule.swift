// The music brain's backup module (docs/brain-spec.md, 12.2, 13.2): what cannot be worked out again and is the listener's own: the
// random salt that makes their lists differ from other installs', the taste changes they made, and the plays and groups of plays they
// asked the brain not to count. Everything else the brain holds (affinities, islands, embeddings, the learned weights, the saved plan,
// the shelf bandit) is a cache that a replay of the event log makes again, so it is not in the backup. The event log itself is the
// listener's history and has its own modules (playback history, imported history).
//
// A port of Android's `BrainBackupFormat.kt`: the same payload, so an Android archive's `brain.json` is read here and this app's is
// read there. Pure text in and out; the app (`BackupService`) puts the pieces back where this phone keeps them.
//
// One difference the payload cannot hide: `adjustments` is the text of the taste changes as the exporting app stores them. This app
// keeps its own JSON for them, so text written by the other platform is not read here (`adjustments` comes back as given and the
// app leaves its own taste changes alone when it cannot read it). Salt and exclusions cross platforms unchanged.

import Foundation
import PixlFoundation

/// One row of the `feedback` table: an exclusion ("Don't count this") or another recorded choice.
public struct BrainBackupFeedbackRow: Sendable, Equatable {
    public var id: Int64
    public var kind: Int32
    public var targetKind: Int32
    public var targetId: Int64
    public var createdAtMs: Int64
    public var undoneAtMs: Int64?

    public init(id: Int64, kind: Int32, targetKind: Int32, targetId: Int64, createdAtMs: Int64, undoneAtMs: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.targetKind = targetKind
        self.targetId = targetId
        self.createdAtMs = createdAtMs
        self.undoneAtMs = undoneAtMs
    }
}

/// What the module holds.
public struct BrainBackupPayload: Sendable, Equatable {
    /// The salt as decimal text; nil when the install had none yet.
    public var salt: String?
    /// The taste changes as the exporting app stores them; "" for none.
    public var adjustments: String
    public var feedback: [BrainBackupFeedbackRow]

    public init(salt: String?, adjustments: String, feedback: [BrainBackupFeedbackRow]) {
        self.salt = salt
        self.adjustments = adjustments
        self.feedback = feedback
    }
}

public enum BrainBackupModule {
    public static let format = "brain-backup-v1"

    /// Most rows a backup may hold: a payload with more is refused, so a damaged file cannot fill the store.
    public static let maxFeedback = 20_000

    public static func export(_ payload: BrainBackupPayload) -> String {
        var root = JSONObject()
        root.append("format", .string(format))
        if let salt = payload.salt { root.append("salt", .string(salt)) }
        root.append("adjustments", .string(payload.adjustments))
        let rows: [JSONValue] = payload.feedback.map { row in
            .object(JSONObject([
                ("id", GsonValue.long(row.id)), ("kind", GsonValue.int(row.kind)), ("targetKind", GsonValue.int(row.targetKind)),
                ("targetId", GsonValue.long(row.targetId)), ("createdAtMs", GsonValue.long(row.createdAtMs)),
                ("undoneAtMs", GsonValue.long(row.undoneAtMs)),
            ]))
        }
        root.append("feedback", .array(rows))
        return GsonWriter.backup(.object(root))
    }

    /// The parsed payload, or nil for anything that is not a well-formed brain backup. Never throws.
    public static func decode(_ text: String) -> BrainBackupPayload? {
        guard let parsed = try? Gson.parse(text), case .object(let root) = parsed else { return nil }
        guard root["format"]?.stringValue == format else { return nil }
        var salt: String?
        if let value = root["salt"], !value.isNull {
            guard let text = value.stringValue, Int64(text) != nil else { return nil }
            salt = text
        }
        var adjustments = ""
        if let value = root["adjustments"], !value.isNull {
            guard let text = value.stringValue else { return nil }
            adjustments = text
        }
        guard let array = root["feedback"]?.arrayValue, array.count <= maxFeedback else { return nil }
        var rows: [BrainBackupFeedbackRow] = []
        rows.reserveCapacity(array.count)
        for element in array {
            guard case .object(let o) = element, let id = o["id"]?.int64Value, let kind = o["kind"]?.int64Value,
                  let targetKind = o["targetKind"]?.int64Value, let targetId = o["targetId"]?.int64Value,
                  let created = o["createdAtMs"]?.int64Value, created >= 0,
                  kind >= Int64(Int32.min), kind <= Int64(Int32.max), targetKind >= Int64(Int32.min), targetKind <= Int64(Int32.max)
            else { return nil }
            var undone: Int64?
            if let value = o["undoneAtMs"], !value.isNull {
                guard let u = value.int64Value else { return nil }
                undone = u
            }
            rows.append(BrainBackupFeedbackRow(id: id, kind: Int32(kind), targetKind: Int32(targetKind), targetId: targetId,
                                               createdAtMs: created, undoneAtMs: undone))
        }
        return BrainBackupPayload(salt: salt, adjustments: adjustments, feedback: rows)
    }

    /// What a restore reads: the payload, or the error Android's handler throws.
    public static func restore(payload: String) throws(BackupError) -> BrainBackupPayload {
        guard let parsed = decode(payload) else { throw BackupError("The brain backup could not be read.") }
        return parsed
    }
}
