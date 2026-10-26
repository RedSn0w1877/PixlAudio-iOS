// The built-in Anthropic key as the build carries it (spec A1): CI splits the ANTHROPIC_API_KEY secret into XOR shares
// of equal length (`ci/write-anthropic-key.sh` → `App/Generated/AnthropicKey.swift`), so the key never sits in the
// binary as one string. The committed file holds no shares: such builds have no built-in key and every AI feature
// stays on the device. The combined key lives only in memory and is never logged.

import Foundation

public enum ClaudeKeyShares {
    /// XORs the shares back into the key; nil when there are none, their lengths differ, or the result isn't a
    /// plausible key (printable ASCII without spaces).
    public static func combine(_ shares: [[UInt8]]) -> String? {
        guard let first = shares.first, !first.isEmpty, shares.allSatisfy({ $0.count == first.count }) else { return nil }
        var bytes = first
        for share in shares.dropFirst() {
            for index in bytes.indices { bytes[index] ^= share[index] }
        }
        guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Splits a key into `count` shares (`count - 1` random, the last the key XOR the others): what the CI script does.
    public static func split(_ key: String, count: Int, random: () -> UInt8) -> [[UInt8]] {
        let bytes = Array(key.utf8)
        guard count > 1 else { return [bytes] }
        var shares: [[UInt8]] = (1..<count).map { _ in bytes.map { _ in random() } }
        var last = bytes
        for share in shares {
            for index in last.indices { last[index] ^= share[index] }
        }
        shares.append(last)
        return shares
    }

    /// Removes the key from text bound for a log or a report (Diagnostics strips it from everything it exports).
    public static func redact(_ text: String, key: String?) -> String {
        guard let key, key.count >= 8 else { return text }
        return text.replacingOccurrences(of: key, with: "[redacted]")
    }
}
