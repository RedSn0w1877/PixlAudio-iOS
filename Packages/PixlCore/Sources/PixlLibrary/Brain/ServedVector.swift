// The feature vector a pick was served with (docs/brain-spec.md, 5.9 "Timing": `x` is computed when the track starts and held with
// the queue entry), kept with the play so the learner trains, and the gate predicts, on exactly what the ranker saw. A transliteration
// of the Android `:brain` module's `ServedVector.kt`.
//
// Stage 3 trained on a REDUCED vector recomputed from the log (no graph, islands, tags, repeat activation, popularity or freshness:
// deviation 160); stage 4 stores the served one.
//
// Quantised so a row stays small and so a live update and a replay read the same numbers: each of the 51 entries is rounded to
// `1/4096` and kept as a little-endian signed 16-bit integer (102 bytes; a value past +-8 is clipped, and the learner refuses
// anything past `Ranker.xMax` in any case). Text form: lower-case hex, 204 characters. A value that does not read back as exactly
// `bytes` bytes is "no served vector": the replay then falls back to the reduced vector, as it does for every older row.

/// The quantised served vector.
public enum ServedVector {
    public static let scale = 4096.0
    public static let bytes = Ranker.d * 2
    private static let limit: Int64 = 32767

    /// The 102 bytes of `x` (length `Ranker.d`). A value that is not finite is stored as 0.
    public static func quantize(_ x: [Double]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes)
        for i in 0..<Ranker.d {
            let v = x[i]
            var q: Int64 = (v.isNaN || v.isInfinite) ? 0 : BrainMath.floorToLong(v * scale + 0.5)
            if q > limit { q = limit }
            if q < -limit { q = -limit }
            let u = Int(q & 0xFFFF)
            out[2 * i] = UInt8(u & 0xFF)
            out[2 * i + 1] = UInt8((u >> 8) & 0xFF)
        }
        return out
    }

    /// The vector `data` holds, or nil when it is not exactly `bytes` long.
    public static func dequantize(_ data: [UInt8]?) -> [Double]? {
        guard let data, data.count == bytes else { return nil }
        var out = [Double](repeating: 0.0, count: Ranker.d)
        for i in 0..<Ranker.d {
            let u = Int(data[2 * i]) | (Int(data[2 * i + 1]) << 8)
            let signed = u >= 0x8000 ? u - 0x10000 : u
            out[i] = Double(signed) / scale
        }
        return out
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    public static func toHex(_ data: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for b in data {
            s.append(hexDigits[Int(b >> 4)])
            s.append(hexDigits[Int(b & 15)])
        }
        return s
    }

    /// The bytes of lower-case hex `text`; nil for a text of the wrong length or with any other character.
    public static func fromHex(_ text: String?) -> [UInt8]? {
        guard let text else { return nil }
        let units = Array(text.utf16)
        if units.count != bytes * 2 { return nil }
        var out = [UInt8](repeating: 0, count: bytes)
        for i in 0..<bytes {
            let hi = digit(units[2 * i])
            let lo = digit(units[2 * i + 1])
            if hi < 0 || lo < 0 { return nil }
            out[i] = UInt8((hi << 4) | lo)
        }
        return out
    }

    private static func digit(_ c: UInt16) -> Int {
        if c >= 48 && c <= 57 { return Int(c) - 48 }
        if c >= 97 && c <= 102 { return Int(c) - 97 + 10 }
        return -1
    }
}
