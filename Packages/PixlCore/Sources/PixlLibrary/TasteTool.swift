// The pure half of Taizo's `adjust_taste`, `list_taste_adjustments` and `remove_taste_adjustment` (spec taizo-taste §2):
// reading the tool's input, resolving each target against the library, turning that into `TasteChange`s, and writing what
// happened back to the model in plain JSON. The app (`TaizoToolbox`) only runs the plan against the store.

import Foundation
import PixlFoundation
import PixlModel

public enum TasteToolPlanner {
    /// One entry of `adjust_taste`, after resolving.
    public enum Entry: Sendable, Hashable {
        case change(TasteChange, TasteTargetResolver.Resolved)
        case rejected(label: String, message: String)
    }

    public struct Plan: Sendable, Hashable {
        public var entries: [Entry]

        /// The changes to apply, in order.
        public var changes: [TasteChange] {
            var out: [TasteChange] = []
            for entry in entries {
                if case .change(let change, _) = entry { out.append(change) }
            }
            return out
        }
    }

    public enum Failure: Error, Sendable, Hashable {
        case noAdjustments
        case tooMany(Int)

        public var message: String {
            switch self {
            case .noAdjustments: "adjustments is empty. Name what to change."
            case .tooMany(let count):
                "\(count) changes in one call; the limit is \(TasteAdjustmentList.maxPerCall). Split them over several calls."
            }
        }
    }

    /// Reads `adjustments` and resolves every target in `songs`. An entry that cannot be resolved is rejected on its own;
    /// the others still apply.
    public static func plan(input: JSONObject, songs: [Song], source: TasteAdjustmentSource = .taizo) -> Result<Plan, Failure> {
        let raw = input["adjustments"]?.arrayValue ?? []
        if raw.isEmpty { return .failure(.noAdjustments) }
        if raw.count > TasteAdjustmentList.maxPerCall { return .failure(.tooMany(raw.count)) }
        var entries: [Entry] = []
        var types = Set<TasteTargetType>()
        for item in raw {
            if let type = item["target_type"]?.stringValue.flatMap(TasteTargetType.init(rawValue:)) { types.insert(type) }
        }
        let keys = TasteLibraryKeys(songs: songs, types: types)
        for item in raw {
            let target = (item["target"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let action = item["action"]?.stringValue.flatMap(TasteAction.init(rawValue:)),
                  let type = item["target_type"]?.stringValue.flatMap(TasteTargetType.init(rawValue:)) else {
                entries.append(.rejected(label: target, message: "Unknown action or target_type."))
                continue
            }
            switch TasteTargetResolver.resolve(type: type, target: target, songs: songs, keys: keys) {
            case .failure(let failure):
                entries.append(.rejected(label: target, message: failure.message))
            case .success(let resolved):
                let strength = item["strength"]?.int64Value.map { Int(min(max($0, 1), 3)) } ?? 2
                let days = item["expires_days"]?.int64Value.map { Int(min(max($0, 1), Int64(TasteAdjustmentList.maxExpiryDays))) }
                let change = TasteChange(action: action, targetType: type, key: resolved.key, label: resolved.label, strength: strength,
                                         reason: item["reason"]?.stringValue ?? "", expiresDays: days, source: source)
                entries.append(.change(change, resolved))
            }
        }
        return .success(Plan(entries: entries))
    }

    /// What each entry did, for the model to report. `outcomes` are the results of `plan.changes`, in order.
    public static func report(plan: Plan, outcomes: [TasteChangeOutcome], nowMs: Int64) -> JSONValue {
        var results: [JSONValue] = []
        var next = 0
        var applied = 0
        for entry in plan.entries {
            switch entry {
            case .rejected(let label, let message):
                results.append(object([("target", .string(label)), ("status", .string("not_applied")), ("detail", .string(message))]))
            case .change(let change, let resolved):
                let outcome = next < outcomes.count ? outcomes[next] : .listFull
                next += 1
                var members: [(String, JSONValue)] = [("target", .string(change.label)), ("target_type", .string(change.targetType.rawValue)),
                                                      ("action", .string(change.action.rawValue))]
                switch outcome {
                case .set(let adjustment, let replaced):
                    applied += 1
                    members.append(("status", .string(replaced == nil ? "applied" : "replaced_earlier_change")))
                    members.append(("id", .string(adjustment.id)))
                    if adjustment.kind.isWeight { members.append(("strength", .integer(adjustment.strength))) }
                    if let expires = adjustment.expiresMs {
                        members.append(("expires_in_days", .integer(Int(max(expires - nowMs, 0) / 86_400_000))))
                    }
                    if !resolved.inLibrary { members.append(("note", .string("Not in the library: it applies to this artist's music wherever it appears."))) }
                    members.append(("undo", .string("remove_taste_adjustment with this id, or Settings > Library & storage > Ask Taizo's taste changes.")))
                case .removed(let gone):
                    applied += 1
                    members.append(("status", .string("removed")))
                    members.append(("removed_id", .string(gone.id)))
                case .nothingToRemove:
                    members.append(("status", .string("not_applied")))
                    members.append(("detail", .string("It was not \(change.action == .unmute ? "muted" : "blocked").")))
                case .listFull:
                    members.append(("status", .string("not_applied")))
                    members.append(("detail", .string("The list is full (\(TasteAdjustmentList.maxItems)). Remove some first.")))
                }
                results.append(object(members))
            }
        }
        return object([("applied", .integer(applied)), ("results", .array(results))])
    }

    // MARK: Listing and removing

    public static func listJSON(_ adjustments: [TasteAdjustment], nowMs: Int64) -> JSONValue {
        let active = adjustments.filter { $0.isActive(nowMs: nowMs) }
            .sorted { $0.createdMs != $1.createdMs ? $0.createdMs > $1.createdMs : $0.id < $1.id }
        return object([("count", .integer(active.count)), ("adjustments", .array(active.map { item in
            var members: [(String, JSONValue)] = [
                ("id", .string(item.id)), ("action", .string(item.kind.rawValue)), ("target_type", .string(item.targetType.rawValue)),
                ("target", .string(item.label)),
            ]
            if item.kind.isWeight { members.append(("strength", .integer(item.strength))) }
            members.append(("reason", .string(item.reason)))
            members.append(("set_by", .string(item.source.rawValue)))
            members.append(("age_days", .integer(Int(max(nowMs - item.createdMs, 0) / 86_400_000))))
            if let expires = item.expiresMs { members.append(("expires_in_days", .integer(Int(max(expires - nowMs, 0) / 86_400_000)))) }
            return object(members)
        }))])
    }

    static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { (key: $0.0, value: $0.1) }))
    }
}
