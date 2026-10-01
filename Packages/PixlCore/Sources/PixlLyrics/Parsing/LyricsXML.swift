// A small, strict, non-validating XML 1.0 + Namespaces reader for lyrics documents (TTML). It reproduces what the
// Android parser is configured to do (JDK/Xerces `DocumentBuilderFactory`, namespace aware, secure processing,
// `disallow-doctype-decl`): any DOCTYPE is an error, so no entity other than the five predefined ones and numeric
// character references can exist, and nothing external is ever loaded. Every well-formedness error the TTML path
// can meet makes the whole parse fail, as Xerces' fatal errors do. FoundationXML's `XMLParser` is not used: it is
// libxml2 on Windows and a different engine on Apple platforms, and neither rejects a DOCTYPE the same way.

import Foundation
import PixlFoundation

/// A parsed XML node (only what the lyrics code needs).
struct LyricsXMLNode: Sendable {
    enum Kind: Sendable {
        case element
        case text
        case cdata
        /// Comments and processing instructions (kept so text around them stays in separate nodes, as in a DOM).
        case other
    }

    var kind: Kind
    /// Qualified name (`tt:p`) for elements.
    var name: String = ""
    /// Local name (after the prefix) for elements.
    var localName: String = ""
    /// Attributes by qualified name, in document order.
    var attributes: [(name: String, value: String)] = []
    /// Character data for text and CDATA nodes.
    var text: String = ""
    var children: [LyricsXMLNode] = []

    /// DOM `Element.getAttribute(qualifiedName)`: the value, or "" when absent.
    func attribute(_ qualifiedName: String) -> String {
        attributes.first { $0.name.isIdentical(to: qualifiedName) }?.value ?? ""
    }

    /// DOM `getElementsByTagNameNS("*", localName)`: descendant elements in document order (not self).
    func descendants(localName: String) -> [LyricsXMLNode] {
        var out: [LyricsXMLNode] = []
        // Iterative pre-order walk (document order).
        var stack: [(node: LyricsXMLNode, next: Int)] = [(self, 0)]
        while !stack.isEmpty {
            let top = stack.count - 1
            let (node, next) = stack[top]
            if next >= node.children.count {
                stack.removeLast()
                continue
            }
            stack[top].next += 1
            let child = node.children[next]
            guard child.kind == .element else { continue }
            if child.localName.isIdentical(to: localName) { out.append(child) }
            stack.append((child, 0))
        }
        return out
    }
}

/// Parse failure (any XML fatal error).
struct LyricsXMLError: Error, Sendable {
    let message: String
}

enum LyricsXMLParser {
    /// Deepest accepted element nesting (a stack-safety bound; Android has none).
    static let maxDepth = 128

    /// Parses a complete document and returns its root element.
    static func parse(_ text: String) throws(LyricsXMLError) -> LyricsXMLNode {
        var reader = Reader(text)
        return try reader.document()
    }

    private struct Reader {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ text: String) {
            // XML end-of-line handling: \r\n and lone \r become \n before parsing.
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(text.unicodeScalars.count)
            var previousCR = false
            for scalar in text.unicodeScalars {
                if scalar == "\r" {
                    out.append("\n")
                    previousCR = true
                    continue
                }
                if scalar == "\n" && previousCR {
                    previousCR = false
                    continue
                }
                previousCR = false
                out.append(scalar)
            }
            s = out
        }

        func fail(_ message: String) -> LyricsXMLError { LyricsXMLError(message: message) }

        var atEnd: Bool { i >= s.count }

        func peek(_ literal: String, at offset: Int = 0) -> Bool {
            var j = i + offset
            for scalar in literal.unicodeScalars {
                guard j < s.count, s[j] == scalar else { return false }
                j += 1
            }
            return true
        }

        static func isXMLWhitespace(_ c: Unicode.Scalar) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r"
        }

        /// XML 1.0 `Char`.
        static func isXMLChar(_ c: Unicode.Scalar) -> Bool {
            let v = c.value
            return v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v)
                || (0x10000...0x10FFFF).contains(v)
        }

        static func isNameStart(_ c: Unicode.Scalar) -> Bool {
            let v = c.value
            if (0x61...0x7A).contains(v) || (0x41...0x5A).contains(v) || v == 0x5F || v == 0x3A { return true }
            return (0xC0...0xD6).contains(v) || (0xD8...0xF6).contains(v) || (0xF8...0x2FF).contains(v)
                || (0x370...0x37D).contains(v) || (0x37F...0x1FFF).contains(v) || (0x200C...0x200D).contains(v)
                || (0x2070...0x218F).contains(v) || (0x2C00...0x2FEF).contains(v) || (0x3001...0xD7FF).contains(v)
                || (0xF900...0xFDCF).contains(v) || (0xFDF0...0xFFFD).contains(v) || (0x10000...0xEFFFF).contains(v)
        }

        static func isNameChar(_ c: Unicode.Scalar) -> Bool {
            if isNameStart(c) { return true }
            let v = c.value
            return v == 0x2D || v == 0x2E || (0x30...0x39).contains(v) || v == 0xB7 || (0x300...0x36F).contains(v)
                || (0x203F...0x2040).contains(v)
        }

        mutating func skipWhitespace() {
            while i < s.count, Self.isXMLWhitespace(s[i]) { i += 1 }
        }

        mutating func name() throws(LyricsXMLError) -> String {
            guard i < s.count, Self.isNameStart(s[i]) else { throw fail("Expected a name") }
            let start = i
            i += 1
            while i < s.count, Self.isNameChar(s[i]) { i += 1 }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: s[start..<i])
            return String(view)
        }

        // MARK: Document

        mutating func document() throws(LyricsXMLError) -> LyricsXMLNode {
            if peek("<?xml"), i + 5 < s.count, Self.isXMLWhitespace(s[i + 5]) || peek("?>", at: 5) {
                try processingInstruction(allowDeclaration: true)
            }
            try misc()
            guard peek("<"), !peek("<!"), !peek("<?") else {
                if peek("<!DOCTYPE") { throw fail("DOCTYPE is disallowed") }
                throw fail("Content is not allowed in prolog")
            }
            var scopes: [[String: String]] = [["xml": "http://www.w3.org/XML/1998/namespace"]]
            let root = try rootElement(scopes: &scopes)
            try misc()
            guard atEnd else { throw fail("Markup after the root element must be well-formed") }
            return root
        }

        /// Comments, processing instructions and whitespace (prolog / epilog).
        mutating func misc() throws(LyricsXMLError) {
            while true {
                skipWhitespace()
                if peek("<!--") {
                    _ = try comment()
                } else if peek("<?") {
                    try processingInstruction(allowDeclaration: false)
                } else if peek("<!DOCTYPE") {
                    throw fail("DOCTYPE is disallowed")
                } else {
                    return
                }
            }
        }

        mutating func comment() throws(LyricsXMLError) -> LyricsXMLNode {
            i += 4
            while i < s.count {
                if s[i] == "-" && peek("--") {
                    guard peek("-->") else { throw fail("'--' is not allowed in comments") }
                    i += 3
                    return LyricsXMLNode(kind: .other)
                }
                guard Self.isXMLChar(s[i]) else { throw fail("Invalid XML character") }
                i += 1
            }
            throw fail("Unterminated comment")
        }

        mutating func processingInstruction(allowDeclaration: Bool) throws(LyricsXMLError) {
            i += 2
            let target = try name()
            if target.lowercased() == "xml" && !allowDeclaration { throw fail("Reserved processing instruction target") }
            if !peek("?>") {
                guard i < s.count, Self.isXMLWhitespace(s[i]) else { throw fail("Malformed processing instruction") }
            }
            while i < s.count {
                if peek("?>") {
                    i += 2
                    return
                }
                guard Self.isXMLChar(s[i]) else { throw fail("Invalid XML character") }
                i += 1
            }
            throw fail("Unterminated processing instruction")
        }

        // MARK: Elements

        /// Reads a start tag (at `<`), pushing its namespace scope. Returns the element and whether it was `<…/>`;
        /// the caller pops the scope when the element ends.
        mutating func startTag(scopes: inout [[String: String]]) throws(LyricsXMLError) -> (LyricsXMLNode, Bool) {
            i += 1 // <
            let qname = try name()
            var rawAttributes: [(name: String, value: String)] = []
            var selfClosing = false
            while true {
                let hadSpace = i < s.count && Self.isXMLWhitespace(s[i])
                skipWhitespace()
                guard i < s.count else { throw fail("Unterminated start tag") }
                if peek("/>") { i += 2; selfClosing = true; break }
                if s[i] == ">" { i += 1; break }
                guard hadSpace else { throw fail("Whitespace required between attributes") }
                let attributeName = try name()
                skipWhitespace()
                guard i < s.count, s[i] == "=" else { throw fail("Expected '=' after attribute name") }
                i += 1
                skipWhitespace()
                let value = try attributeValue()
                if rawAttributes.contains(where: { $0.name.isIdentical(to: attributeName) }) { throw fail("Duplicate attribute") }
                rawAttributes.append((attributeName, value))
            }

            // Namespace declarations of this element, then prefix binding checks.
            var scope = scopes[scopes.count - 1]
            for attribute in rawAttributes {
                if attribute.name == "xmlns" {
                    scope[""] = attribute.value
                } else if attribute.name.hasPrefix("xmlns:") {
                    let prefix = String(attribute.name.dropFirst(6))
                    if attribute.value.isEmpty { throw fail("Empty namespace for a prefix") }
                    if prefix == "xmlns" { throw fail("The xmlns prefix cannot be declared") }
                    if prefix == "xml" && attribute.value != "http://www.w3.org/XML/1998/namespace" {
                        throw fail("The xml prefix is reserved")
                    }
                    scope[prefix] = attribute.value
                }
            }
            let (prefix, local) = try split(qname)
            if let prefix, scope[prefix] == nil { throw fail("Unbound element prefix") }
            var seenExpanded: [(String, String)] = []
            for attribute in rawAttributes where attribute.name != "xmlns" && !attribute.name.hasPrefix("xmlns:") {
                let (attributePrefix, attributeLocal) = try split(attribute.name)
                if let attributePrefix {
                    guard let uri = scope[attributePrefix] else { throw fail("Unbound attribute prefix") }
                    if seenExpanded.contains(where: { $0.0 == uri && $0.1 == attributeLocal }) {
                        throw fail("Duplicate namespaced attribute")
                    }
                    seenExpanded.append((uri, attributeLocal))
                }
            }
            scopes.append(scope)
            return (LyricsXMLNode(kind: .element, name: qname, localName: local, attributes: rawAttributes), selfClosing)
        }

        /// The root element and everything inside it, read iteratively (no recursion, so deep documents cannot
        /// overflow the stack before the depth limit rejects them).
        mutating func rootElement(scopes: inout [[String: String]]) throws(LyricsXMLError) -> LyricsXMLNode {
            let (root, rootSelfClosing) = try startTag(scopes: &scopes)
            if rootSelfClosing {
                scopes.removeLast()
                return root
            }
            var stack: [LyricsXMLNode] = [root]
            var textRun = String.UnicodeScalarView()
            func flush(_ stack: inout [LyricsXMLNode], _ run: inout String.UnicodeScalarView) {
                if !run.isEmpty {
                    stack[stack.count - 1].children.append(LyricsXMLNode(kind: .text, text: String(run)))
                    run = String.UnicodeScalarView()
                }
            }
            while true {
                guard i < s.count else { throw fail("Unterminated element") }
                let c = s[i]
                if c == "<" {
                    if peek("</") {
                        flush(&stack, &textRun)
                        i += 2
                        let closing = try name()
                        skipWhitespace()
                        guard i < s.count, s[i] == ">" else { throw fail("Malformed end tag") }
                        i += 1
                        let finished = stack.removeLast()
                        guard closing.isIdentical(to: finished.name) else { throw fail("Mismatched end tag") }
                        scopes.removeLast()
                        if stack.isEmpty { return finished }
                        stack[stack.count - 1].children.append(finished)
                    } else if peek("<!--") {
                        flush(&stack, &textRun)
                        stack[stack.count - 1].children.append(try comment())
                    } else if peek("<![CDATA[") {
                        flush(&stack, &textRun)
                        i += 9
                        var data = String.UnicodeScalarView()
                        while true {
                            guard i < s.count else { throw fail("Unterminated CDATA section") }
                            if peek("]]>") { i += 3; break }
                            guard Self.isXMLChar(s[i]) else { throw fail("Invalid XML character") }
                            data.append(s[i])
                            i += 1
                        }
                        stack[stack.count - 1].children.append(LyricsXMLNode(kind: .cdata, text: String(data)))
                    } else if peek("<?") {
                        flush(&stack, &textRun)
                        try processingInstruction(allowDeclaration: false)
                        stack[stack.count - 1].children.append(LyricsXMLNode(kind: .other))
                    } else if peek("<!") {
                        throw fail("Markup declarations are not allowed in content")
                    } else {
                        flush(&stack, &textRun)
                        let (child, selfClosing) = try startTag(scopes: &scopes)
                        if selfClosing {
                            scopes.removeLast()
                            stack[stack.count - 1].children.append(child)
                        } else {
                            if stack.count + 1 > LyricsXMLParser.maxDepth { throw fail("Nesting too deep") }
                            stack.append(child)
                        }
                    }
                } else if c == "&" {
                    textRun.append(contentsOf: try reference())
                } else {
                    if c == "]" && peek("]]>") { throw fail("']]>' is not allowed in content") }
                    guard Self.isXMLChar(c) else { throw fail("Invalid XML character") }
                    textRun.append(c)
                    i += 1
                }
            }
        }

        func split(_ qname: String) throws(LyricsXMLError) -> (prefix: String?, local: String) {
            let parts = qname.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 1 { return (nil, qname) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw fail("Malformed qualified name") }
            return (String(parts[0]), String(parts[1]))
        }

        mutating func attributeValue() throws(LyricsXMLError) -> String {
            guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw fail("Open quote expected") }
            let quote = s[i]
            i += 1
            var value = String.UnicodeScalarView()
            while true {
                guard i < s.count else { throw fail("Unterminated attribute value") }
                let c = s[i]
                if c == quote { i += 1; break }
                if c == "<" { throw fail("'<' is not allowed in attribute values") }
                if c == "&" {
                    value.append(contentsOf: try reference())
                    continue
                }
                guard Self.isXMLChar(c) else { throw fail("Invalid XML character") }
                // Attribute-value normalisation: literal whitespace characters become spaces.
                value.append(c == "\t" || c == "\n" || c == "\r" ? " " : c)
                i += 1
            }
            return String(value)
        }

        /// `&name;` (predefined only — there is no DTD) or a character reference.
        mutating func reference() throws(LyricsXMLError) -> [Unicode.Scalar] {
            i += 1 // &
            if i < s.count, s[i] == "#" {
                i += 1
                var radix: UInt32 = 10
                if i < s.count, s[i] == "x" { radix = 16; i += 1 }
                var value: UInt32 = 0
                var digits = 0
                while i < s.count, s[i] != ";" {
                    let c = s[i]
                    let digit: UInt32
                    switch c.value {
                    case 0x30...0x39: digit = c.value - 0x30
                    case 0x61...0x66 where radix == 16: digit = c.value - 0x61 + 10
                    case 0x41...0x46 where radix == 16: digit = c.value - 0x41 + 10
                    default: throw fail("Invalid character reference")
                    }
                    value = value &* radix &+ digit
                    if value > 0x10FFFF { throw fail("Invalid character reference") }
                    digits += 1
                    i += 1
                }
                guard digits > 0, i < s.count else { throw fail("Invalid character reference") }
                i += 1 // ;
                guard let scalar = Unicode.Scalar(value), Self.isXMLChar(scalar) else {
                    throw fail("Invalid character reference")
                }
                return [scalar]
            }
            let entity = try name()
            guard i < s.count, s[i] == ";" else { throw fail("Entity reference must end with ';'") }
            i += 1
            switch entity {
            case "amp": return ["&"]
            case "lt": return ["<"]
            case "gt": return [">"]
            case "quot": return ["\""]
            case "apos": return ["'"]
            default: throw fail("Undeclared entity")
            }
        }
    }
}
