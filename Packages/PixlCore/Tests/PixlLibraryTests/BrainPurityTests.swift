import Foundation
import Testing
@testable import PixlLibrary

/// The brain's pure core (`Sources/PixlLibrary/Brain/`) may not use anything whose result differs between the JVM,
/// ART and Swift (docs/brain-spec.md, 10.3 and 10.4): no libm, no platform hashing, no clock, no locale, no regular
/// expression, no I/O. The file-backed store lives in `BrainStore/`, outside this scan, on purpose.
@Suite("Brain purity")
struct BrainPurityTests {
    /// A banned call, and whether it must stand alone as an identifier (`log(` but not `catalog(`).
    private let banned: [(needle: String, wholeWord: Bool, why: String)] = [
        ("import Foundation", false, "the core is standard-library Swift only"),
        ("import Darwin", false, "no libm"),
        ("import Glibc", false, "no libm"),
        ("import ucrt", false, "no libm"),
        ("import CRT", false, "no libm"),
        ("import Musl", false, "no libm"),
        ("log1p(", true, "use BrainMath"),
        ("expm1(", true, "use BrainMath"),
        ("sin(", true, "not in the contract"),
        ("cos(", true, "not in the contract"),
        ("tan(", true, "not in the contract"),
        ("cbrt(", true, "not in the contract"),
        ("sqrt(", true, "use BrainMath.sqrt"),
        ("floor(", true, "use BrainMath.floorToLong"),
        ("round(", true, "use BrainMath.floorToLong(x + 0.5)"),
        ("lround(", true, "use BrainMath.floorToLong(x + 0.5)"),
        ("fma(", true, "no fused multiply-add"),
        ("log(", true, "use BrainMath.ln (10.2)"),
        ("log2(", true, "use BrainMath.log2"),
        ("log10(", true, "use BrainMath"),
        ("exp(", true, "use BrainMath.exp"),
        ("pow(", true, "use BrainMath.powNeg"),
        ("addingProduct(", false, "no fused multiply-add"),
        (".hashValue", false, "use BrainHash.fnv1a64"),
        ("Hasher()", false, "use BrainHash.fnv1a64"),
        ("Date(", true, "time enters as nowMs"),
        ("DispatchTime", false, "time enters as nowMs"),
        ("ContinuousClock", false, "time enters as nowMs"),
        ("Locale", true, "no locale APIs"),
        ("TimeZone", true, "time enters as nowMs and tzOffsetMin"),
        ("Calendar", true, "time enters as nowMs and tzOffsetMin"),
        ("Regex", true, "no regular expressions in the core"),
        ("NSRegularExpression", false, "no regular expressions in the core"),
        (".lowercased(", false, "use BrainText.fold"),
        (".uppercased(", false, "use BrainText.fold"),
        (".localizedCompare(", false, "strings are never ordered as strings"),
        (".random(", false, "use BrainHash.Rng"),
        ("SystemRandomNumberGenerator", false, "use BrainHash.Rng"),
        (".shuffled(", false, "use BrainHash.Rng"),
        ("FileManager", false, "no I/O in the core"),
        ("FileHandle", false, "no I/O in the core"),
        ("URLSession", false, "no I/O in the core"),
        ("UserDefaults", false, "no I/O in the core"),
    ]

    /// Removes comments and string literals so prose and table contents cannot trip the scan.
    private func codeOnly(_ source: String) -> String {
        let chars = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar = i + 1 < chars.count ? chars[i + 1] : " "
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                out.append(contentsOf: "\"\"".unicodeScalars)
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    private func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    /// The brain's own functions carry the names of the banned ones (`BrainMath.exp` is not libm's `exp`): a match
    /// that is a call through `BrainMath.` or the declaration itself (`func exp(`) is ours.
    private let ownPrefixes = ["BrainMath.", "func "]

    private func contains(_ code: String, _ needle: String, wholeWord: Bool) -> Bool {
        var searchFrom = code.startIndex
        while let range = code.range(of: needle, range: searchFrom..<code.endIndex) {
            if !wholeWord { return true }
            let before = code[code.startIndex..<range.lowerBound]
            let standsAlone = range.lowerBound == code.startIndex
                || !isIdentifierScalar(code.unicodeScalars[code.unicodeScalars.index(before: range.lowerBound)])
            let isOurs = ownPrefixes.contains { before.hasSuffix($0) }
            if standsAlone && !isOurs { return true }
            searchFrom = range.upperBound
        }
        return false
    }

    @Test func noBannedImportOrCallInTheBrainSources() throws {
        let brain = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PixlLibrary/Brain", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: brain.path).filter { $0.hasSuffix(".swift") }
        #expect(names.count >= 22, "expected the whole core at \(brain.path), found \(names.count) files")
        var violations: [String] = []
        for name in names {
            let source = try String(contentsOf: brain.appendingPathComponent(name), encoding: .utf8)
            let code = codeOnly(source)
            for rule in banned where contains(code, rule.needle, wholeWord: rule.wholeWord) {
                violations.append("\(name): `\(rule.needle)` (\(rule.why))")
            }
            // The square root and rounding down are the two platform operations the contract allows, in one place.
            if name != "BrainMath.swift" {
                for needle in [".squareRoot(", ".rounded(", ".round("] where contains(code, needle, wholeWord: false) {
                    violations.append("\(name): `\(needle)` (go through BrainMath)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test func theScanSeesCodeAndIgnoresCommentsAndStrings() {
        let code = codeOnly("let a = \"Date() log(\" // exp(1)\n/* pow( */ let b = catalog(1); let c = Date()")
        #expect(!contains(code, "log(", wholeWord: true))
        #expect(!contains(code, "exp(", wholeWord: true))
        #expect(!contains(code, "pow(", wholeWord: true))
        #expect(contains(code, "Date(", wholeWord: true))
    }

    @Test func theScanTellsOurOwnMathsFromThePlatforms() {
        #expect(contains(codeOnly("let y = exp(1.0)"), "exp(", wholeWord: true))
        #expect(contains(codeOnly("let y = Foundation.exp(1.0)"), "exp(", wholeWord: true))
        #expect(contains(codeOnly("let y = 2 * log2(x)"), "log2(", wholeWord: true))
        #expect(!contains(codeOnly("let y = BrainMath.exp(1.0) // exp( is banned"), "exp(", wholeWord: true))
        #expect(!contains(codeOnly("public static func exp(_ x: Double) -> Double { x }"), "exp(", wholeWord: true))
        #expect(!contains(codeOnly("let y = BrainMath.log2(x)"), "log2(", wholeWord: true))
    }
}
