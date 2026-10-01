// Kotlin/JVM string semantics the ported library code depends on. Swift's `String` compares and hashes by Unicode
// canonical equivalence and orders by scalar value; Kotlin compares UTF-16 code units exactly. These helpers let
// the ports keep the Android behaviour (sort order, map keys, case folding) instead of silently changing it.

import Foundation
import PixlFoundation

/// A string key with Kotlin equality: two keys are equal only when their code units are identical ("é" and
/// "e\u{301}" are different keys, as in a Kotlin `HashMap`).
public struct KotlinKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) { self.value = value }

    public static func == (lhs: KotlinKey, rhs: KotlinKey) -> Bool { KotlinText.equals(lhs.value, rhs.value) }

    public func hash(into hasher: inout Hasher) {
        var copy = value
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    public var description: String { value }
}

/// Kotlin/Java string operations.
public enum KotlinText {
    // MARK: Comparison

    /// `String.compareTo`: lexicographic over UTF-16 code units.
    public static func compare(_ a: String, _ b: String) -> Int {
        var ia = a.utf16.makeIterator()
        var ib = b.utf16.makeIterator()
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?): if x != y { return x < y ? -1 : 1 }
            }
        }
    }

    /// SQLite `BINARY` collation: memcmp over UTF-8 (code point order).
    public static func compareBinary(_ a: String, _ b: String) -> Int {
        var ia = a.utf8.makeIterator()
        var ib = b.utf8.makeIterator()
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?): if x != y { return x < y ? -1 : 1 }
            }
        }
    }

    /// SQLite `NOCASE` collation: ASCII letters folded to lower case, then memcmp over UTF-8.
    public static func compareNoCase(_ a: String, _ b: String) -> Int {
        var ia = a.utf8.makeIterator()
        var ib = b.utf8.makeIterator()
        func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c }
        while true {
            switch (ia.next(), ib.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?):
                let fx = fold(x), fy = fold(y)
                if fx != fy { return fx < fy ? -1 : 1 }
            }
        }
    }

    /// `String.equals`: identical code units.
    public static func equals(_ a: String, _ b: String) -> Bool {
        var x = a, y = b
        return x.withUTF8 { bx in
            y.withUTF8 { by in
                bx.count == by.count && (bx.count == 0 || memcmp(bx.baseAddress!, by.baseAddress!, bx.count) == 0)
            }
        }
    }

    /// Whether every code unit is ASCII (the fast path of the case and normalisation helpers).
    @inline(__always)
    static func isASCII(_ s: String) -> Bool {
        var copy = s
        return copy.withUTF8 { buffer in buffer.allSatisfy { $0 < 0x80 } }
    }

    // MARK: Case mapping

    /// `Character.toUpperCase(int)` (simple mapping), approximated from the Unicode scalar properties: the full
    /// upper-case mapping when it is a single scalar, else the title-case mapping when that is a single scalar
    /// (covers the Greek iota-subscript letters), else unchanged (`ß`, `ŉ` …, as on the JVM).
    public static func simpleUppercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            return (0x61...0x7A).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x20)! : scalar
        }
        if let single = singleScalar(scalar.properties.uppercaseMapping) { return single }
        if let single = singleScalar(scalar.properties.titlecaseMapping) { return single }
        return scalar
    }

    /// `Character.toLowerCase(int)` (simple mapping): the full lower-case mapping when it is a single scalar, else
    /// unchanged; `İ` (U+0130) maps to `i` as on the JVM.
    public static func simpleLowercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            return (0x41...0x5A).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
        }
        if scalar.value == 0x130 { return "i" }
        return singleScalar(scalar.properties.lowercaseMapping) ?? scalar
    }

    /// `Character.toLowerCase(Character.toUpperCase(c))` — the fold java.util.regex uses with `UNICODE_CASE`.
    @inlinable
    public static func regexFold(_ scalar: Unicode.Scalar) -> Unicode.Scalar { simpleLowercase(simpleUppercase(scalar)) }

    private static func singleScalar(_ s: String) -> Unicode.Scalar? {
        var it = s.unicodeScalars.makeIterator()
        guard let first = it.next(), it.next() == nil else { return nil }
        return first
    }

    /// Kotlin `lowercase()` (`toLowerCase(Locale.ROOT)`): full lower-case mapping with the final-sigma rule.
    public static func lowercase(_ s: String) -> String {
        if isASCII(s) {
            var copy = s
            return copy.withUTF8 { buffer in
                String(decoding: buffer.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 }, as: UTF8.self)
            }
        }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            if scalar.isASCII {
                out.append(simpleLowercase(scalar))
            } else if scalar.value == 0x3A3, isFinalSigma(scalars, i) {
                out.append("\u{3C2}")
            } else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// Kotlin `uppercase()` (`toUpperCase(Locale.ROOT)`): full upper-case mapping.
    public static func uppercase(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.isASCII { out.append(simpleUppercase(scalar)) } else {
                out.append(contentsOf: scalar.properties.uppercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
        var i = index - 1
        while i >= 0, scalars[i].properties.isCaseIgnorable { i -= 1 }
        guard i >= 0, scalars[i].properties.isCased else { return false }
        var j = index + 1
        while j < scalars.count, scalars[j].properties.isCaseIgnorable { j += 1 }
        return !(j < scalars.count && scalars[j].properties.isCased)
    }

    /// Whether two scalars are equal ignoring case the way `String.regionMatches(ignoreCase = true)` decides.
    @inlinable
    public static func scalarEqualsIgnoreCase(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if a == b { return true }
        let ua = simpleUppercase(a), ub = simpleUppercase(b)
        if ua == ub { return true }
        return simpleLowercase(ua) == simpleLowercase(ub)
    }

    /// Kotlin `String.equals(other, ignoreCase = true)`.
    public static func equalsIgnoreCase(_ a: String, _ b: String) -> Bool {
        let sa = Array(a.unicodeScalars), sb = Array(b.unicodeScalars)
        guard a.utf16.count == b.utf16.count, sa.count == sb.count else { return false }
        for (x, y) in zip(sa, sb) where !scalarEqualsIgnoreCase(x, y) { return false }
        return true
    }

    /// Kotlin `CharSequence.contains(other, ignoreCase)`.
    public static func contains(_ s: String, _ other: String, ignoreCase: Bool) -> Bool {
        indexOf(Array(s.unicodeScalars), Array(other.unicodeScalars), from: 0, ignoreCase: ignoreCase) != nil
    }

    /// Kotlin `String.startsWith(prefix, ignoreCase)`.
    public static func startsWith(_ s: String, _ prefix: String, ignoreCase: Bool) -> Bool {
        let a = Array(s.unicodeScalars), p = Array(prefix.unicodeScalars)
        guard p.count <= a.count else { return false }
        for i in 0..<p.count {
            if ignoreCase ? !scalarEqualsIgnoreCase(a[i], p[i]) : a[i] != p[i] { return false }
        }
        return true
    }

    static func indexOf(_ s: [Unicode.Scalar], _ needle: [Unicode.Scalar], from: Int, ignoreCase: Bool) -> Int? {
        if needle.isEmpty { return min(from, s.count) }
        guard needle.count <= s.count else { return nil }
        var i = from
        while i + needle.count <= s.count {
            var ok = true
            for j in 0..<needle.count {
                let equal = ignoreCase ? scalarEqualsIgnoreCase(s[i + j], needle[j]) : s[i + j] == needle[j]
                if !equal { ok = false; break }
            }
            if ok { return i }
            i += 1
        }
        return nil
    }

    // MARK: Editing

    /// Kotlin `String.replace(oldValue, newValue)` (literal, case-sensitive, left to right).
    public static func replace(_ s: String, _ oldValue: String, _ newValue: String) -> String {
        let text = Array(s.utf16), old = Array(oldValue.utf16), new = Array(newValue.utf16)
        guard var occurrence = utf16IndexOf(text, old, from: 0) else { return s }
        let step = max(old.count, 1)
        var out: [UInt16] = []
        out.reserveCapacity(text.count)
        var i = 0
        repeat {
            out.append(contentsOf: text[i..<occurrence])
            out.append(contentsOf: new)
            i = occurrence + old.count
            if occurrence >= text.count { break }
            guard let next = utf16IndexOf(text, old, from: occurrence + step) else { break }
            occurrence = next
        } while occurrence > 0
        out.append(contentsOf: text[min(i, text.count)...])
        return String(decoding: out, as: UTF16.self)
    }

    static func utf16IndexOf(_ text: [UInt16], _ needle: [UInt16], from: Int) -> Int? {
        let start = max(from, 0)
        if needle.isEmpty { return start <= text.count ? start : nil }
        guard needle.count <= text.count else { return nil }
        var i = start
        while i + needle.count <= text.count {
            if text[i] == needle[0] {
                var ok = true
                for j in 1..<needle.count where text[i + j] != needle[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    /// Kotlin `substringAfterLast(delimiter)`: the part after the last occurrence, or the whole string.
    public static func substringAfterLast(_ s: String, _ delimiter: Unicode.Scalar) -> String {
        let scalars = s.unicodeScalars
        guard let index = scalars.lastIndex(of: delimiter) else { return s }
        return String(scalars[scalars.index(after: index)...])
    }

    /// Kotlin `substringBeforeLast(delimiter)` with an explicit missing value.
    public static func substringBeforeLast(_ s: String, _ delimiter: Unicode.Scalar, missing: String) -> String {
        let scalars = s.unicodeScalars
        guard let index = scalars.lastIndex(of: delimiter) else { return missing }
        return String(scalars[..<index])
    }

    /// Kotlin `removeSuffix(suffix)` (exact code units).
    public static func removeSuffix(_ s: String, _ suffix: String) -> String {
        let a = Array(s.utf16), b = Array(suffix.utf16)
        guard b.count <= a.count, Array(a[(a.count - b.count)...]) == b else { return s }
        return String(decoding: a[..<(a.count - b.count)], as: UTF16.self)
    }

    // MARK: Hashing and normalisation

    /// `String.hashCode()` (Java: `s[0]*31^(n-1) + … + s[n-1]` over UTF-16, wrapping).
    public static func hashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return h
    }

    /// `Normalizer.normalize(s, NFC)`.
    public static func nfc(_ s: String) -> String { isASCII(s) ? s : s.precomposedStringWithCanonicalMapping }

    /// `Normalizer.normalize(s, NFKC)`.
    public static func nfkc(_ s: String) -> String { isASCII(s) ? s : s.precomposedStringWithCompatibilityMapping }

    /// Kotlin `replace(Regex("\\s+"), " ")` — runs of Java `\s` (`[ \t\n\x0B\f\r]`) become one space.
    public static func collapseJavaWhitespace(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in s.unicodeScalars {
            if isJavaWhitespace(scalar.value) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return String(out)
    }

    /// java.util.regex `\s` without `UNICODE_CHARACTER_CLASS`.
    @inlinable
    public static func isJavaWhitespace(_ unit: UInt32) -> Bool {
        unit == 0x20 || (unit >= 0x09 && unit <= 0x0D)
    }

    /// Kotlin `String.trim()`.
    @inlinable
    public static func trim(_ s: String) -> String { s.kotlinTrimmed() }

    /// Kotlin `String.isBlank()`.
    @inlinable
    public static func isBlank(_ s: String) -> Bool { s.isKotlinBlank }
}

// MARK: - Stable sorting with Kotlin comparators

extension Sequence {
    /// A stable sort (Kotlin's `sortedWith` is a stable TimSort). `comparator` returns <0, 0 or >0.
    public func kotlinSorted(by comparator: (Element, Element) -> Int) -> [Element] {
        let indexed = Array(enumerated())
        return indexed.sorted { a, b in
            let c = comparator(a.element, b.element)
            return c != 0 ? c < 0 : a.offset < b.offset
        }.map(\.element)
    }

    /// Kotlin `distinctBy` with Kotlin string equality on the selected key (first occurrence wins).
    public func kotlinDistinct(by key: (Element) -> String) -> [Element] {
        var seen = Set<KotlinKey>()
        var out: [Element] = []
        for element in self where seen.insert(KotlinKey(key(element))).inserted { out.append(element) }
        return out
    }
}

extension Sequence where Element == String {
    /// Kotlin `distinct()` on strings (exact code units, first occurrence wins).
    public func kotlinDistinct() -> [String] { kotlinDistinct { $0 } }
}

/// Builds a Kotlin-style comparator chain: the first non-zero comparison wins.
@inlinable
func chain(_ comparisons: Int...) -> Int {
    for c in comparisons where c != 0 { return c }
    return 0
}

@inlinable
func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }

/// An insertion-ordered dictionary keyed with Kotlin string equality (`LinkedHashMap<String, V>`).
public struct OrderedStringMap<Value> {
    public private(set) var keys: [String] = []
    private var storage: [KotlinKey: Value] = [:]

    public init() {}

    public subscript(key: String) -> Value? {
        get { storage[KotlinKey(key)] }
        set {
            let k = KotlinKey(key)
            if let newValue {
                if storage.updateValue(newValue, forKey: k) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: k) != nil {
                keys.removeAll { KotlinText.equals($0, key) }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [Value] { keys.map { storage[KotlinKey($0)]! } }
    public var entries: [(key: String, value: Value)] { keys.map { ($0, storage[KotlinKey($0)]!) } }

    /// Appends to the list stored under `key` in place (Kotlin `groupBy`).
    public mutating func append<Element>(_ element: Element, to key: String) where Value == [Element] {
        let k = KotlinKey(key)
        if storage[k] == nil { keys.append(key) }
        storage[k, default: []].append(element)
    }

    /// Adds `amount` to the number stored under `key` (Kotlin `groupingBy { }.eachCount()` / `merge`).
    public mutating func add(_ amount: Value, to key: String) where Value: AdditiveArithmetic {
        let k = KotlinKey(key)
        if storage[k] == nil { keys.append(key) }
        storage[k, default: .zero] += amount
    }

    /// `getOrPut`.
    public mutating func getOrPut(_ key: String, _ make: () -> Value) -> Value {
        if let existing = self[key] { return existing }
        let value = make()
        self[key] = value
        return value
    }
}

extension OrderedStringMap: Sendable where Value: Sendable {}
