// The canonical `brain-snapshot-v1` (docs/brain-spec.md, 3.8, 10.1, 10.3): the affinity tables, the pseudo-counts and
// the completion counts as one JSON object, rows in the canonical order of 10.3, rule 2. It is the fixture format of
// the golden vectors and of the evaluation harness, and (from stage 3) the `brain` backup module. A transliteration of
// the Android `:brain` module's `Snapshot.kt`.
//
// Stage 2a holds the affinity state only; islands, ranker weights and posteriors arrive with the stages that own
// them, as new keys beside `rows` (a reader ignores keys it does not know).
//
// Each row is `[storedFamily, key, posQ, negQ, lastMs, posRQ, negRQ, lastRMs]` with the family codes of `Family`: 0-7
// by key, then the sums (16+), the pseudo-counts (32+) and the completion counts (48).

/// The snapshot codec.
public enum Snapshot {
    public static let format = "brain-snapshot-v1"

    public enum Failure: Error, Equatable {
        case notASnapshot(String)
    }

    public static func encode(_ state: Affinity.State) -> String {
        var w = BrainJson.Writer()
        w.beginObject()
        w.string("format", format)
        w.int("specVersion", Brain.specVersion)
        w.beginArray("rows")
        for row in state.rows() {
            let k = row.counter
            w.beginArray()
            w.intItem(row.family); w.longItem(row.key); w.longItem(k.posQ); w.longItem(k.negQ); w.longItem(k.lastMs)
            w.longItem(k.posRQ); w.longItem(k.negRQ); w.longItem(k.lastRMs)
            w.endArray()
        }
        w.endArray()
        w.endObject()
        return w.text
    }

    /// The state `encode` wrote. Throws for text that is not a snapshot.
    public static func decode(_ text: String) throws -> Affinity.State {
        guard let root = try? BrainJson.parse(text) else { throw Failure.notASnapshot("not an object") }
        guard let name = root["format"]?.stringValue, BrainKey.sameBytes(name, format) else { throw Failure.notASnapshot("not a \(format)") }
        guard let rows = root["rows"]?.arrayValue else { throw Failure.notASnapshot("no rows") }
        var state = Affinity.State()
        for r in rows {
            guard let row = r.arrayValue else { throw Failure.notASnapshot("bad row") }
            if row.count != 8 { throw Failure.notASnapshot("bad row length \(row.count)") }
            func long(_ i: Int) throws -> Int64 {
                if let v = row[i].longValue { return v }
                throw Failure.notASnapshot("bad number in row")
            }
            state.load(storedFamily: Int32(truncatingIfNeeded: try long(0)), key: try long(1), posQ: try long(2),
                       negQ: try long(3), lastMs: try long(4), posRQ: try long(5), negRQ: try long(6),
                       lastRMs: try long(7))
        }
        return state
    }
}
