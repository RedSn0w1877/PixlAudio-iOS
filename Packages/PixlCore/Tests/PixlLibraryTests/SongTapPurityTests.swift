import Foundation
import Testing
@testable import PixlLibrary

/// Song Tap's pure core (`Sources/PixlLibrary/SongTap/`) may not reach for anything whose result differs between the JVM,
/// ART and Swift: no Foundation, no platform types, no clock, no randomness, no I/O, no cryptography (each app injects its
/// own), no floating point, no locale-dependent text calls (the Android `PurityTest`, with the Swift names).
@Suite("Song Tap purity")
struct SongTapPurityTests {
    private let banned: [(needle: String, wholeWord: Bool, why: String)] = [
        ("import Foundation", false, "the core is standard-library Swift only"),
        ("import Darwin", false, "no libm"),
        ("import Glibc", false, "no libm"),
        ("import ucrt", false, "no libm"),
        ("import CRT", false, "no libm"),
        ("import Musl", false, "no libm"),
        ("import CryptoKit", false, "the crypto is injected by each app"),
        ("import Security", false, "the crypto is injected by each app"),
        ("import CoreBluetooth", false, "no platform types in the core"),
        ("import SwiftUI", false, "no platform types in the core"),
        ("import UIKit", false, "no platform types in the core"),
        ("Double", true, "no floating point in the core"),
        ("Float", true, "no floating point in the core"),
        ("CGFloat", true, "no floating point in the core"),
        ("sqrt(", true, "integer arithmetic only"),
        ("squareRoot(", false, "integer arithmetic only"),
        (".rounded(", false, "integer arithmetic only"),
        ("pow(", true, "integer arithmetic only"),
        ("exp(", true, "integer arithmetic only"),
        ("log(", true, "integer arithmetic only"),
        ("Date(", true, "time enters as nowMs"),
        ("DispatchTime", false, "time enters as nowMs"),
        ("ContinuousClock", false, "time enters as nowMs"),
        ("ProcessInfo", false, "time enters as nowMs"),
        ("Locale", true, "no locale APIs"),
        ("TimeZone", true, "time enters as nowMs"),
        ("Calendar", true, "time enters as nowMs"),
        ("Regex", true, "no regular expressions in the core"),
        ("NSRegularExpression", false, "no regular expressions in the core"),
        (".lowercased(", false, "no locale-dependent case mapping"),
        (".uppercased(", false, "no locale-dependent case mapping"),
        (".hashValue", false, "no platform hashes"),
        ("Hasher()", false, "no platform hashes"),
        (".random(", false, "randomness enters as arguments"),
        ("SystemRandomNumberGenerator", false, "randomness enters as arguments"),
        (".shuffled(", false, "randomness enters as arguments"),
        ("FileManager", false, "no I/O in the core"),
        ("URLSession", false, "no I/O in the core"),
        ("UserDefaults", false, "no I/O in the core"),
        ("Thread", true, "no threads in the core"),
        ("DispatchQueue", false, "no threads in the core"),
        ("String(format", false, "no formatting APIs in the core"),
        (".precomposedStringWithCanonicalMapping", false, "no platform text normalisation"),
        (".decomposedStringWithCanonicalMapping", false, "no platform text normalisation"),
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

    private func contains(_ code: String, _ needle: String, wholeWord: Bool) -> Bool {
        var searchFrom = code.startIndex
        while let range = code.range(of: needle, range: searchFrom..<code.endIndex) {
            if !wholeWord { return true }
            let before = range.lowerBound == code.startIndex ? nil : code.unicodeScalars[code.unicodeScalars.index(before: range.lowerBound)]
            let after = range.upperBound == code.endIndex ? nil : code.unicodeScalars[range.upperBound]
            let startsAlone = before.map { !isIdentifierScalar($0) } ?? true
            // A needle that ends in a letter must not run into a longer name (`Double` but not `DoubleQuote`).
            let endsAlone = needle.unicodeScalars.last.map { !isIdentifierScalar($0) } == true || after.map { !isIdentifierScalar($0) } ?? true
            if startsAlone && endsAlone { return true }
            searchFrom = range.upperBound
        }
        return false
    }

    /// The ring code's image side (`ring/image`: style, renderer, scanner) measures pixels and needs floating point and Foundation's
    /// maths; it is checked by round trips, not by golden vectors (the Android `PurityTest`'s `floatingPointOk`). Everything else
    /// in the core, the ring code's layout, Reed-Solomon, payload and timeline included, stays integer only.
    private let imageSideOk: Set<String> = [
        "import Foundation", "Double", "Float", "CGFloat", "sqrt(", "squareRoot(", ".rounded(", "pow(", "exp(", "log(",
    ]

    private func isImageSide(_ path: String) -> Bool { path.replacingOccurrences(of: "\\", with: "/").contains("/ring/image/") }

    /// Every .swift file under the Song Tap folder (the ring code lives in `ring/` and `ring/image/`), as full paths.
    private func swiftFiles(under folder: URL) throws -> [String] {
        var out: [String] = []
        for entry in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { out += try swiftFiles(under: url) } else if entry.hasSuffix(".swift") { out.append(url.path) }
        }
        return out.sorted()
    }

    private var songTapFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PixlLibrary/SongTap", isDirectory: true)
    }

    @Test func noBannedImportOrCallInTheSongTapSources() throws {
        let paths = try swiftFiles(under: songTapFolder)
        #expect(paths.count >= 10, "expected the whole core at \(songTapFolder.path), found \(paths.count) files")
        var violations: [String] = []
        for path in paths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let code = codeOnly(source)
            let name = (path as NSString).lastPathComponent
            for rule in banned where contains(code, rule.needle, wholeWord: rule.wholeWord) {
                if isImageSide(path) && imageSideOk.contains(rule.needle) { continue }
                violations.append("\(name): `\(rule.needle)` (\(rule.why))")
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test func theImageSideIsTheOnlyPlaceFloatingPointMayLive() throws {
        let paths = try swiftFiles(under: songTapFolder)
        let ringStrict = paths.filter { $0.replacingOccurrences(of: "\\", with: "/").contains("/ring/") && !isImageSide($0) }
        #expect(ringStrict.count >= 5, "the strict ring files: \(ringStrict.map { ($0 as NSString).lastPathComponent })")
        let image = paths.filter { isImageSide($0) }
        #expect(image.count >= 3, "the image side files: \(image.map { ($0 as NSString).lastPathComponent })")
        for path in ringStrict {
            let code = codeOnly(try String(contentsOfFile: path, encoding: .utf8))
            for needle in imageSideOk { #expect(!contains(code, needle, wholeWord: needle != "import Foundation"), "\((path as NSString).lastPathComponent) uses `\(needle)`") }
        }
    }

    @Test func theCoreHasTheSameFileNamesAsAndroid() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PixlLibrary/SongTap", isDirectory: true)
        let names = Set(try swiftFiles(under: folder).map { ($0 as NSString).lastPathComponent })
        for expected in ["SongTapText", "SongTapPayload", "SongTapLink", "SongTapSigning", "SongTapSession", "SongTapRateLimits",
                         "SongTapDetector", "SongTapTimeline", "SongTapHandshake",
                         "RingCodeLayout", "Gf256", "ReedSolomon", "RingCodePayload", "RingCodeTimeline", "RingFlow",
                         "RingCodeRenderer", "RingCodeStyle", "RingScanner"] {
            #expect(names.contains("\(expected).swift"), "\(expected).swift is missing")
        }
    }

    @Test func theScanSeesCodeAndIgnoresCommentsAndStrings() {
        #expect(contains(codeOnly("let x: Double = 1"), "Double", wholeWord: true))
        #expect(contains(codeOnly("import Foundation"), "import Foundation", wholeWord: false))
        #expect(!contains(codeOnly("let a = \"Double\" // Float"), "Double", wholeWord: true))
        #expect(!contains(codeOnly("let a = 1 /* Date() */"), "Date(", wholeWord: true))
        #expect(!contains(codeOnly("let DoubleQuote = 1"), "Double", wholeWord: true))
        #expect(contains(codeOnly("let d = Date()"), "Date(", wholeWord: true))
        #expect(!contains(codeOnly("let d = candidate()"), "Date(", wholeWord: true))
    }
}
