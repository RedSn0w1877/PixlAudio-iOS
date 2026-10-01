// A minimal, safe YAML reader for Lyricsfile documents (LRCLIB `lyricsfile`, draft 1.0). It covers the YAML that
// format uses — block mappings and sequences (including compact `- key: value` items and sequences at their
// parent key's indentation), flow `{}`/`[]` collections, plain/single-quoted/double-quoted scalars with line
// folding, `|`/`>` block scalars, comments, `---`/`...` markers, anchors with scalar aliases, the `!!str` tag —
// and mirrors how the Android app configures SnakeYAML: every scalar is a string (YAML 1.2 text, so "No"/"On" stay
// words), duplicate keys, aliases of collections and nesting deeper than 20 are errors, there is exactly one
// document, and nothing is ever constructed from a tag. Anything outside the subset is an error, never a guess.

import Foundation
import PixlFoundation

/// A YAML node with every scalar kept as text.
indirect enum LyricsfileYAMLNode: Sendable, Equatable {
    case scalar(String)
    case sequence([LyricsfileYAMLNode])
    case mapping([(key: String, value: LyricsfileYAMLNode)])

    static func == (lhs: LyricsfileYAMLNode, rhs: LyricsfileYAMLNode) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let a), .scalar(let b)): return a == b
        case (.sequence(let a), .sequence(let b)): return a == b
        case (.mapping(let a), .mapping(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// Mapping member (keys are unique).
    subscript(key: String) -> LyricsfileYAMLNode? {
        guard case .mapping(let members) = self else { return nil }
        return members.first { $0.key.isIdentical(to: key) }?.value
    }

    /// Java `toString()` of the value SnakeYAML builds (`String`, `ArrayList`, `LinkedHashMap`).
    var javaString: String {
        switch self {
        case .scalar(let s): return s
        case .sequence(let items): return "[" + items.map(\.javaString).joined(separator: ", ") + "]"
        case .mapping(let members): return "{" + members.map { $0.key + "=" + $0.value.javaString }.joined(separator: ", ") + "}"
        }
    }
}

struct LyricsfileYAMLError: Error, Sendable {
    let message: String
}

enum LyricsfileYAML {
    /// SnakeYAML `LoaderOptions.nestingDepthLimit` as the Android app sets it.
    static let nestingDepthLimit = 20

    /// The single document of `text`; nil for an empty stream.
    static func load(_ text: String) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode? {
        var parser = Parser(text)
        return try parser.stream()
    }

    private struct Parser {
        var s: [Unicode.Scalar]
        var i = 0
        var lineStart = 0
        var anchors: [String: LyricsfileYAMLNode] = [:]
        var depth = 0

        init(_ text: String) {
            var out: [Unicode.Scalar] = []
            var previousCR = false
            for scalar in text.unicodeScalars {
                if scalar == "\r" { out.append("\n"); previousCR = true; continue }
                if scalar == "\n" && previousCR { previousCR = false; continue }
                previousCR = false
                out.append(scalar)
            }
            if out.first?.value == 0xFEFF { out.removeFirst() }
            s = out
        }

        func fail(_ message: String) -> LyricsfileYAMLError { LyricsfileYAMLError(message: message) }

        var atEnd: Bool { i >= s.count }
        var column: Int { i - lineStart }
        func char(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < s.count ? s[i + offset] : nil }

        static func isBlank(_ c: Unicode.Scalar?) -> Bool { c == nil || c == " " || c == "\t" || c == "\n" }
        static func isSpaceOrTab(_ c: Unicode.Scalar?) -> Bool { c == " " || c == "\t" }
        static func isFlowIndicator(_ c: Unicode.Scalar?) -> Bool { c == "," || c == "[" || c == "]" || c == "{" || c == "}" }

        /// YAML printable characters (SnakeYAML rejects anything else).
        static func isPrintable(_ c: Unicode.Scalar) -> Bool {
            let v = c.value
            return v == 0x9 || v == 0xA || v == 0xD || (0x20...0x7E).contains(v) || v == 0x85 || (0xA0...0xD7FF).contains(v)
                || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
        }

        mutating func advanceLine() {
            while i < s.count, s[i] != "\n" { i += 1 }
            if i < s.count { i += 1 }
            lineStart = i
        }

        /// Skips spaces on the current line, then a comment. Like SnakeYAML, a tab where the next token would start
        /// is an error (tabs are only accepted inside scalars).
        mutating func skipInlineSpaceAndComment() throws(LyricsfileYAMLError) {
            while char() == " " { i += 1 }
            if char() == "\t" { throw fail("A tab cannot start a token") }
            if char() == "#", i == lineStart || Self.isBlank(s[i - 1]) {
                while i < s.count, s[i] != "\n" { i += 1 }
            }
        }

        /// Moves to the first content character of the next non-blank, non-comment line (from the start of a line
        /// or the end of a content line). Tabs may not indent content.
        mutating func skipToContent() throws(LyricsfileYAMLError) {
            while true {
                try skipInlineSpaceAndComment()
                guard let c = char() else { return }
                if c == "\n" {
                    i += 1
                    lineStart = i
                    continue
                }
                return
            }
        }

        /// True when at column 0 there is `---` or `...` followed by a blank.
        func atDocumentMarker(_ marker: String) -> Bool {
            guard column == 0 else { return false }
            let m = Array(marker.unicodeScalars)
            for (k, c) in m.enumerated() where char(k) != c { return false }
            return Self.isBlank(char(3))
        }

        // MARK: Stream

        mutating func stream() throws(LyricsfileYAMLError) -> LyricsfileYAMLNode? {
            if let bad = s.first(where: { !Self.isPrintable($0) }) {
                throw fail("Special character U+\(String(bad.value, radix: 16)) is not allowed")
            }
            lineStart = 0
            while char() == " " { i += 1 }
            try skipToContent()
            if char() == "%" && column == 0 { throw fail("Directives are not supported") }
            var explicitStart = false
            if atDocumentMarker("---") {
                explicitStart = true
                i += 3
                try skipToContent()
            }
            var root: LyricsfileYAMLNode?
            if !atEnd && !atDocumentMarker("...") && !atDocumentMarker("---") {
                root = try blockNode(parentIndent: -1)
                try skipToContent()
            } else if explicitStart {
                root = nil
            }
            if atDocumentMarker("...") {
                i += 3
                try skipToContent()
            }
            guard atEnd else {
                if atDocumentMarker("---") { throw fail("Expected a single document in the stream") }
                throw fail("Expected the end of the document")
            }
            return root
        }

        // MARK: Block nodes

        mutating func enter() throws(LyricsfileYAMLError) {
            depth += 1
            if depth > LyricsfileYAML.nestingDepthLimit { throw fail("Nesting depth exceeded") }
        }

        /// A block node whose first character is at the current position (on its line).
        mutating func blockNode(parentIndent: Int) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            let col = column
            var anchor: String?
            if char() == "&" || char() == "!" {
                (anchor) = try properties()
                try skipInlineSpaceAndComment()
                if char() == "\n" || atEnd {
                    try skipToContent()
                    if atEnd || column <= parentIndent { return register(anchor, .scalar("")) }
                    let node = try blockNode(parentIndent: parentIndent)
                    return register(anchor, node)
                }
            }
            if char() == "-" && Self.isBlank(char(1)) {
                return register(anchor, try blockSequence(indent: column))
            }
            if char() == "|" || char() == ">" {
                return register(anchor, .scalar(try blockScalar(parentIndent: parentIndent)))
            }
            if char() == "*" {
                let node = try alias()
                try skipInlineSpaceAndComment()
                if char() == ":" { throw fail("Aliases as mapping keys are not supported") }
                return node
            }
            if char() == "[" || char() == "{" {
                let node = try flowNode()
                try skipInlineSpaceAndComment()
                if char() == ":" { throw fail("Collections as mapping keys are not supported") }
                return register(anchor, node)
            }
            if char() == "?" && Self.isBlank(char(1)) { throw fail("Explicit keys are not supported") }
            // A scalar: a mapping key when followed by ':' on the same line.
            let keyCol = col
            let start = i
            if char() == "'" || char() == "\"" {
                let quoted = try quotedScalar(parentIndent: parentIndent)
                let afterQuote = i
                try skipInlineSpaceAndComment()
                if char() == ":" && Self.isBlank(char(1)) {
                    guard s[start..<afterQuote].firstIndex(of: "\n") == nil else { throw fail("Multi-line key") }
                    return register(anchor, try blockMapping(indent: keyCol, firstKey: quoted))
                }
                return register(anchor, .scalar(quoted))
            }
            if let key = try plainKeyIfMapping() {
                return register(anchor, try blockMapping(indent: keyCol, firstKey: key))
            }
            return register(anchor, .scalar(try plainScalar(parentIndent: parentIndent, flow: false)))
        }

        mutating func register(_ anchor: String?, _ node: LyricsfileYAMLNode) -> LyricsfileYAMLNode {
            if let anchor { anchors[anchor] = node }
            return node
        }

        /// `&anchor` and/or `!!str`; any other tag is rejected (SnakeYAML's safe constructor would refuse or build a
        /// typed value).
        mutating func properties() throws(LyricsfileYAMLError) -> String? {
            var anchor: String?
            var sawTag = false
            while char() == "&" || char() == "!" {
                if char() == "&" {
                    guard anchor == nil else { throw fail("Duplicate anchor") }
                    i += 1
                    let start = i
                    while let c = char(), !Self.isBlank(c), !Self.isFlowIndicator(c) { i += 1 }
                    guard i > start else { throw fail("Empty anchor") }
                    anchor = ParseKit.string(s[start..<i])
                } else {
                    guard !sawTag else { throw fail("Duplicate tag") }
                    sawTag = true
                    let start = i
                    while let c = char(), !Self.isBlank(c) { i += 1 }
                    let tag = ParseKit.string(s[start..<i])
                    guard tag == "!!str" || tag == "!<tag:yaml.org,2002:str>" else { throw fail("Unsupported tag \(tag)") }
                }
                while char() == " " { i += 1 }
            }
            return anchor
        }

        mutating func alias() throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            i += 1
            let start = i
            while let c = char(), !Self.isBlank(c), !Self.isFlowIndicator(c) { i += 1 }
            let name = ParseKit.string(s[start..<i])
            guard let node = anchors[name] else { throw fail("Undefined alias") }
            guard case .scalar = node else { throw fail("Aliases of collections are not allowed") }
            return node
        }

        /// When the current line is `plainKey: …` (or `plainKey:` at the end of the line), consumes the key and
        /// returns it; otherwise leaves the position unchanged.
        mutating func plainKeyIfMapping() throws(LyricsfileYAMLError) -> String? {
            guard canStartPlain() else { throw fail("Unexpected character '\(char().map(String.init) ?? "")'") }
            var j = i
            while j < s.count, s[j] != "\n" {
                if s[j] == ":" && (j + 1 >= s.count || Self.isBlank(s[j + 1])) {
                    var end = j
                    while end > i, Self.isSpaceOrTab(s[end - 1]) { end -= 1 }
                    let key = ParseKit.string(s[i..<end])
                    i = j
                    return key
                }
                if s[j] == "#" && Self.isBlank(s[j - 1]) { return nil }
                j += 1
            }
            return nil
        }

        func canStartPlain() -> Bool {
            guard let c = char() else { return false }
            switch c {
            case "-", "?", ":": return !Self.isBlank(char(1))
            case "[", "]", "{", "}", ",", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`": return false
            default: return !Self.isBlank(c)
            }
        }

        /// A block mapping whose first key (already read, position at its ':') starts at `indent`.
        mutating func blockMapping(indent: Int, firstKey: String) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            try enter()
            defer { depth -= 1 }
            var members: [(key: String, value: LyricsfileYAMLNode)] = []
            var key = firstKey
            while true {
                // At ':'.
                i += 1
                let value = try mappingValue(indent: indent)
                if members.contains(where: { $0.key.isIdentical(to: key) }) { throw fail("Duplicate key \(key)") }
                members.append((key, value))

                try skipToContent()
                if atEnd || column < indent || atDocumentMarker("---") || atDocumentMarker("...") { break }
                guard column == indent else { throw fail("Bad indentation of a mapping entry") }
                if char() == "-" && Self.isBlank(char(1)) { throw fail("Expected a mapping key") }
                if char() == "'" || char() == "\"" {
                    let start = i
                    let quoted = try quotedScalar(parentIndent: indent)
                    guard s[start..<i].firstIndex(of: "\n") == nil else { throw fail("Multi-line key") }
                    while char() == " " { i += 1 }
                    guard char() == ":" && Self.isBlank(char(1)) else { throw fail("Expected ':' after a key") }
                    key = quoted
                } else if char() == "?" && Self.isBlank(char(1)) {
                    throw fail("Explicit keys are not supported")
                } else if char() == "&" || char() == "!" || char() == "*" || char() == "[" || char() == "{" {
                    throw fail("Unsupported mapping key")
                } else {
                    guard let next = try plainKeyIfMapping() else { throw fail("Expected a mapping key") }
                    key = next
                }
            }
            return .mapping(members)
        }

        /// The value after `key:` in a block mapping at `indent`.
        mutating func mappingValue(indent: Int) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            guard Self.isBlank(char()) else { throw fail("Expected a blank after ':'") }
            try skipInlineSpaceAndComment()
            if atEnd || char() == "\n" {
                try skipToContent()
                if atEnd || atDocumentMarker("---") || atDocumentMarker("...") { return .scalar("") }
                if column > indent { return try blockNode(parentIndent: indent) }
                if column == indent && char() == "-" && Self.isBlank(char(1)) {
                    return try blockSequence(indent: indent)
                }
                return .scalar("")
            }
            if char() == "-" && Self.isBlank(char(1)) { throw fail("Sequence entries are not allowed here") }
            let node = try inlineValue(parentIndent: indent)
            return node
        }

        /// A node starting on the same line as its key: no nested block collection may start here.
        mutating func inlineValue(parentIndent: Int) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            var anchor: String?
            if char() == "&" || char() == "!" {
                anchor = try properties()
                try skipInlineSpaceAndComment()
                if atEnd || char() == "\n" {
                    try skipToContent()
                    if atEnd || column <= parentIndent { return register(anchor, .scalar("")) }
                    return register(anchor, try blockNode(parentIndent: parentIndent))
                }
            }
            if char() == "|" || char() == ">" { return register(anchor, .scalar(try blockScalar(parentIndent: parentIndent))) }
            if char() == "*" { return try alias() }
            if char() == "[" || char() == "{" {
                let node = try flowNode()
                return register(anchor, node)
            }
            if char() == "'" || char() == "\"" {
                let value = try quotedScalar(parentIndent: parentIndent)
                try skipInlineSpaceAndComment()
                if char() == ":" && Self.isBlank(char(1)) { throw fail("Mapping values are not allowed here") }
                if !(atEnd || char() == "\n") { throw fail("Unexpected content after a quoted scalar") }
                return register(anchor, .scalar(value))
            }
            guard canStartPlain() else { throw fail("Unexpected character") }
            return register(anchor, .scalar(try plainScalar(parentIndent: parentIndent, flow: false)))
        }

        /// A block sequence whose `-` entries sit at `indent`.
        mutating func blockSequence(indent: Int) throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            try enter()
            defer { depth -= 1 }
            var items: [LyricsfileYAMLNode] = []
            while true {
                // At '-'.
                i += 1
                try skipInlineSpaceAndComment()
                if atEnd || char() == "\n" {
                    try skipToContent()
                    if !atEnd && column > indent && !atDocumentMarker("---") && !atDocumentMarker("...") {
                        items.append(try blockNode(parentIndent: indent))
                    } else {
                        items.append(.scalar(""))
                    }
                } else {
                    items.append(try blockNode(parentIndent: indent))
                }
                try skipToContent()
                if atEnd || column < indent || atDocumentMarker("---") || atDocumentMarker("...") { break }
                if column > indent { throw fail("Bad indentation of a sequence entry") }
                guard char() == "-" && Self.isBlank(char(1)) else { break }
            }
            return .sequence(items)
        }

        // MARK: Scalars

        /// A plain scalar, folding continuation lines indented more than `parentIndent` (block context) or any
        /// lines (flow context).
        mutating func plainScalar(parentIndent: Int, flow: Bool) throws(LyricsfileYAMLError) -> String {
            var result = ""
            var hasContent = false
            var breaksBefore = 0
            while true {
                let contentStart = i
                var end = i
                while let c = char(), c != "\n" {
                    if c == ":" && (Self.isBlank(char(1)) || (flow && Self.isFlowIndicator(char(1)))) {
                        if flow { break }
                        throw fail("Mapping values are not allowed here")
                    }
                    if c == "#" && i > contentStart && Self.isBlank(s[i - 1]) { break }
                    if flow && Self.isFlowIndicator(c) { break }
                    i += 1
                    if !Self.isSpaceOrTab(c) { end = i }
                }
                if end > contentStart {
                    if hasContent {
                        result += breaksBefore == 1 ? " " : String(repeating: "\n", count: breaksBefore - 1)
                    }
                    result += ParseKit.string(s[contentStart..<end])
                    hasContent = true
                }
                i = end
                // Only a line break (after optional white space) can continue the scalar.
                var j = i
                while j < s.count, Self.isSpaceOrTab(s[j]) { j += 1 }
                i = j // trailing spaces and tabs belong to the scalar (SnakeYAML consumes them)
                guard j < s.count, s[j] == "\n" else { return result }
                var breaks = 0
                var p = j
                var pLineStart = lineStart
                while p < s.count, s[p] == "\n" {
                    breaks += 1
                    p += 1
                    pLineStart = p
                    while p < s.count, Self.isSpaceOrTab(s[p]) { p += 1 }
                }
                guard p < s.count else { return result }
                let col = p - pLineStart
                let isMarker = col == 0 && (matches(p, "---") || matches(p, "..."))
                    && Self.isBlank(p + 3 < s.count ? s[p + 3] : nil)
                if s[p] == "#" || isMarker || (!flow && col <= parentIndent) { return result }
                i = p
                lineStart = pLineStart
                if flow && (Self.isFlowIndicator(s[p]) || (s[p] == ":" && (p + 1 >= s.count || Self.isBlank(s[p + 1])))) {
                    return result
                }
                breaksBefore = breaks
            }
        }

        func matches(_ at: Int, _ literal: String) -> Bool {
            var j = at
            for c in literal.unicodeScalars {
                guard j < s.count, s[j] == c else { return false }
                j += 1
            }
            return true
        }

        /// A single- or double-quoted scalar with line folding.
        mutating func quotedScalar(parentIndent: Int) throws(LyricsfileYAMLError) -> String {
            let quote = s[i]
            i += 1
            var out = String.UnicodeScalarView()
            var trailingSpace = String.UnicodeScalarView()
            while true {
                guard let c = char() else { throw fail("Unterminated quoted scalar") }
                if c == quote {
                    if quote == "'" && char(1) == "'" {
                        out.append(contentsOf: trailingSpace); trailingSpace = String.UnicodeScalarView()
                        out.append("'")
                        i += 2
                        continue
                    }
                    i += 1
                    out.append(contentsOf: trailingSpace)
                    return String(out)
                }
                if c == "\n" {
                    // Fold: drop trailing white space, count breaks, skip leading white space.
                    trailingSpace = String.UnicodeScalarView()
                    var breaks = 0
                    while char() == "\n" {
                        breaks += 1
                        i += 1
                        lineStart = i
                        if column == 0 && (atDocumentMarker("---") || atDocumentMarker("...")) {
                            throw fail("Document marker inside a quoted scalar")
                        }
                        while Self.isSpaceOrTab(char()) { i += 1 }
                    }
                    if breaks == 1 { out.append(" ") } else { out.append(contentsOf: String(repeating: "\n", count: breaks - 1).unicodeScalars) }
                    continue
                }
                if c == " " || c == "\t" {
                    trailingSpace.append(c)
                    i += 1
                    continue
                }
                out.append(contentsOf: trailingSpace)
                trailingSpace = String.UnicodeScalarView()
                if quote == "\"" && c == "\\" {
                    i += 1
                    guard let e = char() else { throw fail("Unterminated escape") }
                    i += 1
                    switch e {
                    case "0": out.append("\u{0}")
                    case "a": out.append("\u{7}")
                    case "b": out.append("\u{8}")
                    case "t", "\t": out.append("\t")
                    case "n": out.append("\n")
                    case "v": out.append("\u{B}")
                    case "f": out.append("\u{C}")
                    case "r": out.append("\r")
                    case "e": out.append("\u{1B}")
                    case " ": out.append(" ")
                    case "\"": out.append("\"")
                    case "/": out.append("/")
                    case "\\": out.append("\\")
                    case "N": out.append("\u{85}")
                    case "_": out.append("\u{A0}")
                    case "L": out.append("\u{2028}")
                    case "P": out.append("\u{2029}")
                    case "x", "u", "U":
                        let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                        var value: UInt32 = 0
                        for _ in 0..<count {
                            guard let h = char(), let digit = hexValue(h) else {
                                throw fail("Invalid escape")
                            }
                            value = value * 16 + digit
                            i += 1
                        }
                        guard let scalar = Unicode.Scalar(value) else { throw fail("Invalid escape") }
                        out.append(scalar)
                    case "\n":
                        // Escaped line break: join without a space, skipping the next line's indentation.
                        lineStart = i
                        while Self.isSpaceOrTab(char()) { i += 1 }
                    default:
                        throw fail("Invalid escape")
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
        }

        func hexValue(_ c: Unicode.Scalar) -> UInt32? {
            switch c.value {
            case 0x30...0x39: return c.value - 0x30
            case 0x41...0x46: return c.value - 0x41 + 10
            case 0x61...0x66: return c.value - 0x61 + 10
            default: return nil
            }
        }

        /// `|` or `>` block scalar with optional chomping (`+`/`-`) and indentation digit.
        mutating func blockScalar(parentIndent: Int) throws(LyricsfileYAMLError) -> String {
            let folded = s[i] == ">"
            i += 1
            var chomp: Unicode.Scalar = " "
            var explicitIndent: Int?
            for _ in 0..<2 {
                if let c = char(), c == "+" || c == "-", chomp == " " {
                    chomp = c
                    i += 1
                } else if let c = char(), c.value >= 0x31 && c.value <= 0x39, explicitIndent == nil {
                    explicitIndent = Int(c.value - 0x30)
                    i += 1
                }
            }
            guard Self.isBlank(char()) || char() == "#" else { throw fail("Invalid block scalar header") }
            try skipInlineSpaceAndComment()
            guard atEnd || char() == "\n" else { throw fail("Expected a line break after a block scalar header") }
            if !atEnd { i += 1; lineStart = i }

            // Content lines: nil marks an empty line.
            var lines: [[Unicode.Scalar]?] = []
            var contentIndent: Int? = explicitIndent.map { max(parentIndent, 0) + $0 }
            while !atEnd {
                var j = i
                while j < s.count, s[j] == " " { j += 1 }
                let indent = j - i
                let empty = j >= s.count || s[j] == "\n"
                if !empty {
                    if contentIndent == nil {
                        if indent <= parentIndent { break }
                        contentIndent = indent
                    }
                    let marker = indent == 0 && (matches(j, "---") || matches(j, "..."))
                        && Self.isBlank(j + 3 < s.count ? s[j + 3] : nil)
                    if indent < contentIndent! || marker { break }
                }
                var k = j
                while k < s.count, s[k] != "\n" { k += 1 }
                lines.append(empty ? nil : Array(s[(i + contentIndent!)..<k]))
                i = k < s.count ? k + 1 : k
                lineStart = i
            }

            var trailing = 0
            while let last = lines.last, last == nil {
                trailing += 1
                lines.removeLast()
            }
            if lines.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }

            var body = ""
            if folded {
                var previousNormal: Bool?
                var empties = 0
                for line in lines {
                    guard let line else { empties += 1; continue }
                    let normal = !(line.first == " " || line.first == "\t")
                    if let previousNormal {
                        if previousNormal && normal {
                            body += empties == 0 ? " " : String(repeating: "\n", count: empties)
                        } else {
                            body += String(repeating: "\n", count: empties + 1)
                        }
                    } else {
                        body += String(repeating: "\n", count: empties)
                    }
                    empties = 0
                    body += ParseKit.string(line)
                    previousNormal = normal
                }
            } else {
                body = lines.map { $0.map(ParseKit.string) ?? "" }.joined(separator: "\n")
            }
            switch chomp {
            case "-": return body
            case "+": return body + "\n" + String(repeating: "\n", count: trailing)
            default: return body + "\n"
            }
        }

        // MARK: Flow collections

        mutating func skipFlowSpace() throws(LyricsfileYAMLError) {
            while let c = char() {
                if c == " " { i += 1; continue }
                if c == "\t" { throw fail("A tab cannot start a token") }
                if c == "\n" { i += 1; lineStart = i; continue }
                if c == "#" && (i == lineStart || Self.isBlank(s[i - 1])) {
                    while i < s.count, s[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func flowNode() throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            try enter()
            defer { depth -= 1 }
            let isMap = s[i] == "{"
            let close: Unicode.Scalar = isMap ? "}" : "]"
            i += 1
            var items: [LyricsfileYAMLNode] = []
            var members: [(key: String, value: LyricsfileYAMLNode)] = []
            while true {
                try skipFlowSpace()
                guard let c = char() else { throw fail("Unterminated flow collection") }
                if c == close { i += 1; break }
                if isMap {
                    let key = try flowScalar()
                    try skipFlowSpace()
                    var value: LyricsfileYAMLNode = .scalar("")
                    if char() == ":" {
                        i += 1
                        try skipFlowSpace()
                        if char() != "," && char() != close { value = try flowValue() }
                    }
                    if members.contains(where: { $0.key.isIdentical(to: key) }) { throw fail("Duplicate key \(key)") }
                    members.append((key, value))
                } else {
                    let value = try flowValue()
                    try skipFlowSpace()
                    if char() == ":" { throw fail("Single-pair mappings in flow sequences are not supported") }
                    items.append(value)
                }
                try skipFlowSpace()
                if char() == "," { i += 1; continue }
                if char() == close { i += 1; break }
                throw fail("Expected ',' or '\(close)'")
            }
            return isMap ? .mapping(members) : .sequence(items)
        }

        mutating func flowValue() throws(LyricsfileYAMLError) -> LyricsfileYAMLNode {
            var anchor: String?
            if char() == "&" || char() == "!" {
                anchor = try properties()
                try skipFlowSpace()
            }
            if char() == "[" || char() == "{" { return register(anchor, try flowNode()) }
            if char() == "*" { return try alias() }
            return register(anchor, .scalar(try flowScalar()))
        }

        mutating func flowScalar() throws(LyricsfileYAMLError) -> String {
            if char() == "'" || char() == "\"" { return try quotedScalar(parentIndent: -1) }
            guard canStartPlain() else { throw fail("Unexpected character in a flow collection") }
            return try plainScalar(parentIndent: -1, flow: true)
        }
    }
}
