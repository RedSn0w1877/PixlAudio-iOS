// TTML in the shape of the big streaming catalogs (`<tt>` → `<body>` → `<div>` → `<p begin end ttm:agent>` →
// `<span begin end>`, as BiniLyrics serves it) → a `LyricsDoc`, keeping what the karaoke view can show:
//  - syllable timing with explicit ends; spans with no space between them are one word (`<span>e</span><span>nough
//    </span>`), a space between spans starts a new word;
//  - background vocals (`<span ttm:role="x-bg">`) as background lines, their wrapping parentheses removed;
//  - duets: the first singer (`ttm:agent`, inherited from `div`/`body`) is the lead, any other person is the duet
//    voice, a group agent sings with the lead;
//  - line-only documents (`<p>` with text and no timed spans) as line-synced lines, untimed documents as plain text;
//  - head translations / transliterations (`<text for="L1">`, keyed by `lrc:key`/`itunes:key`) and inline
//    `x-translation` / `x-roman` spans as each lead line's translation and romanisation (on-device romanisation fills
//    the gaps, as `LyricsUtils.parseLyrics` does).
// The legacy `TtmlLyricsParser` (Android's, which flattens everything to enhanced LRC) stays the parser for every
// other TTML; this one is used for BiniLyrics documents. XML goes through `LyricsXMLParser`, which rejects any DOCTYPE,
// so no entity is ever declared or loaded. A document `LyricsDocCodec.isValid` would reject falls back to the legacy
// parser, so nothing usable is lost.

import Foundation
import PixlFoundation
import PixlModel

public enum TtmlDocumentParser {
    /// Largest accepted document, in UTF-16 units.
    public static let maxInputLength = 4 * 1_048_576
    /// Documents with more paragraphs are rejected (as `TtmlLyricsParser`).
    public static let maxParagraphs = TtmlLyricsParser.maxParagraphs

    /// Voice ids written into the document.
    public static let leadVoiceId = "lead"
    public static let duetVoiceId = "duet"
    public static let backgroundVoiceId = "background"

    /// Parses `ttml`. `metadata` becomes the document's metadata (its `source` names the catalog);
    /// `preferredLanguages` (BCP 47, most preferred first) picks among several head translations.
    /// nil when the text is not a well-formed TTML document or holds no lyrics.
    public static func parse(_ ttml: String, metadata: LyricsMetadata = LyricsMetadata(),
                             preferredLanguages: [String] = [],
                             romanization: any CJKRomanizationProvider = NoCJKRomanization()) -> Lyrics? {
        if ttml.utf16.count > maxInputLength { return nil }
        let normalized = TtmlLyricsParser.normalizeTtmlDocument(ttml)
        guard !ParseKit.isBlank(normalized), let root = try? LyricsXMLParser.parse(normalized),
              root.localName.isIdentical(to: "tt") else { return nil }
        do {
            return try Builder(root: root, metadata: metadata, preferredLanguages: preferredLanguages,
                               romanization: romanization).build()
                ?? fallback(ttml, romanization: romanization)
        } catch {
            return nil
        }
    }

    /// The legacy flattening parser, for documents this one cannot express as a valid `LyricsDoc`.
    static func fallback(_ ttml: String, romanization: any CJKRomanizationProvider) -> Lyrics? {
        var lyrics = LyricsUtils.parseLyrics(ttml, romanization: romanization)
        guard LyricsRepositoryLogic.isUsable(lyrics) else { return nil }
        lyrics.areFromRemote = true
        return lyrics
    }

    /// Times: `27.395`, `27.395s`, `1:02.5`, `1:02:03.250`, `500ms`, `2m`, `1h`. Negative values clamp to 0.
    static func timeMs(_ raw: String) throws -> Int64? {
        let value = ParseKit.trim(raw)
        if value.isEmpty { return nil }
        let scalars = Array(value.unicodeScalars)
        func number(dropping suffix: Int) -> Double? { ParseKit.parseDouble(ParseKit.string(scalars.dropLast(suffix))) }
        var ms: Int64?
        if value.hasSuffix("ms"), let n = number(dropping: 2) {
            ms = n.isFinite ? Int64((n).rounded()) : nil
        } else if value.hasSuffix("h"), let n = number(dropping: 1) {
            ms = n.isFinite ? Int64((n * 3_600_000).rounded()) : nil
        } else if value.hasSuffix("m"), let n = number(dropping: 1) {
            ms = n.isFinite ? Int64((n * 60_000).rounded()) : nil
        } else if let parsed = try TtmlLyricsParser.parseTimeExpression(value) {
            ms = Int64(parsed)
        }
        guard let ms else { return nil }
        if ms > LyricsDocCodec.maxDurationMs { return nil }
        return Swift.max(0, ms)
    }

    // MARK: - Building

    /// A piece of a line: a timed span, or untimed text between spans.
    struct Piece {
        var text: String
        var beginMs: Int64?
        var endMs: Int64?
        /// A space (or the line start) comes before it.
        var startsWord: Bool
    }

    /// The pieces of one line (the lead text of a `<p>`, or one background span).
    struct Collector {
        var pieces: [Piece] = []
        var pendingBoundary = false
        var beginMs: Int64?
        var endMs: Int64?

        mutating func append(_ rawText: String, beginMs: Int64?, endMs: Int64?) {
            if rawText.isEmpty { return }
            // Any whitespace between spans (a space, or a pretty-printed line break) separates words.
            if rawText.unicodeScalars.allSatisfy(ParseKit.isWhitespace) {
                pendingBoundary = true
                return
            }
            let text = TtmlLyricsParser.sanitizeTextFragment(rawText)
            if text.isEmpty || text.unicodeScalars.allSatisfy(ParseKit.isRegexSpace) {
                if !text.isEmpty { pendingBoundary = true }
                return
            }
            let leading = text.unicodeScalars.first.map(ParseKit.isRegexSpace) ?? false
            let trailing = text.unicodeScalars.last.map(ParseKit.isRegexSpace) ?? false
            let body = TtmlLyricsParser.replaceRegexSpaceRuns(ParseKit.trim(text))
            pieces.append(Piece(text: body, beginMs: beginMs, endMs: endMs,
                                startsWord: pieces.isEmpty || pendingBoundary || leading))
            pendingBoundary = trailing
        }

        var plainText: String {
            var out = ""
            for (i, piece) in pieces.enumerated() {
                if i > 0 && piece.startsWord { out += " " }
                out += piece.text
            }
            return out
        }
    }

    /// What a `<p>` holds besides its lead text.
    struct Extras {
        var backgrounds: [Collector] = []
        var inlineTranslation: [String] = []
        var inlineRomanization: [String] = []
    }

    /// One `<p>` read into its lead and background parts.
    struct Paragraph {
        var lead: Collector
        var extras: Extras
        var key: String?
        var agent: String?
        var backgrounds: [Collector] { extras.backgrounds }
    }

    /// A built line before it becomes a `TimedLine`.
    struct BuiltLine {
        var startMs: Int64
        var endMs: Int64?
        var text: String
        var voiceId: String
        var syllables: [TimedSyllable]
        /// Index into the paragraphs (lead lines carry translations).
        var paragraph: Int
        var isBackground: Bool
    }

    struct Builder {
        let root: LyricsXMLNode
        let metadata: LyricsMetadata
        let preferredLanguages: [String]
        let romanization: any CJKRomanizationProvider

        func build() throws -> Lyrics? {
            guard let body = root.children.first(where: { $0.kind == .element && $0.localName.isIdentical(to: "body") })
                ?? root.descendants(localName: "body").first else { return nil }
            var located: [(node: LyricsXMLNode, agent: String?)] = []
            collectParagraphs(body, agent: attribute(body, "agent"), into: &located)
            if located.isEmpty || located.count > maxParagraphs { return nil }

            var paragraphs: [Paragraph] = []
            paragraphs.reserveCapacity(located.count)
            for (node, agent) in located {
                var lead = Collector()
                lead.beginMs = try timeMs(node.attribute("begin"))
                lead.endMs = try timeMs(node.attribute("end"))
                var extras = Extras()
                try collect(node, into: &lead, extras: &extras, inBackground: false)
                paragraphs.append(Paragraph(lead: lead, extras: extras, key: attribute(node, "key"), agent: agent))
            }

            let timed = paragraphs.contains { p in
                p.lead.beginMs != nil || p.lead.pieces.contains { $0.beginMs != nil }
                    || p.backgrounds.contains { $0.pieces.contains { $0.beginMs != nil } }
            }
            if !timed { return plainLyrics(paragraphs) }
            return timedLyrics(paragraphs, bodyDurationMs: try timeMs(body.attribute("dur")))
        }

        // MARK: Reading

        /// `<p>` elements in document order with the agent they inherit from `div`/`body`.
        func collectParagraphs(_ node: LyricsXMLNode, agent: String?, into out: inout [(node: LyricsXMLNode, agent: String?)]) {
            var stack: [(node: LyricsXMLNode, agent: String?, next: Int)] = [(node, agent, 0)]
            while !stack.isEmpty {
                let top = stack.count - 1
                let (current, inherited, next) = stack[top]
                if next >= current.children.count {
                    stack.removeLast()
                    continue
                }
                stack[top].next += 1
                let child = current.children[next]
                guard child.kind == .element else { continue }
                let own = attribute(child, "agent") ?? inherited
                if child.localName.isIdentical(to: "p") {
                    out.append((child, own))
                    if out.count > maxParagraphs { return }
                } else if !child.localName.isIdentical(to: "head") && !child.localName.isIdentical(to: "metadata") {
                    stack.append((child, own, 0))
                }
            }
        }

        func collect(_ node: LyricsXMLNode, into collector: inout Collector, extras: inout Extras,
                     inBackground: Bool) throws {
            for child in node.children {
                switch child.kind {
                case .text, .cdata:
                    collector.append(child.text, beginMs: nil, endMs: nil)
                case .other:
                    continue
                case .element:
                    let name = child.localName.lowercased()
                    if name == "br" {
                        collector.pendingBoundary = true
                        continue
                    }
                    guard name == "span" else {
                        try collect(child, into: &collector, extras: &extras, inBackground: inBackground)
                        continue
                    }
                    let role = attribute(child, "role")?.lowercased()
                    if role == "x-bg" && !inBackground {
                        var background = Collector()
                        background.beginMs = try timeMs(child.attribute("begin"))
                        background.endMs = try timeMs(child.attribute("end"))
                        try collect(child, into: &background, extras: &extras, inBackground: true)
                        if !background.pieces.isEmpty { extras.backgrounds.append(background) }
                        continue
                    }
                    if role == "x-translation" {
                        if !inBackground { extras.inlineTranslation.append(Self.textContent(child)) }
                        continue
                    }
                    if role == "x-roman" {
                        if !inBackground { extras.inlineRomanization.append(Self.textContent(child)) }
                        continue
                    }
                    if let begin = try timeMs(child.attribute("begin")), try !Self.hasTimedSpan(child) {
                        collector.append(Self.textContent(child), beginMs: begin, endMs: try timeMs(child.attribute("end")))
                    } else {
                        try collect(child, into: &collector, extras: &extras, inBackground: inBackground)
                    }
                }
            }
        }

        static func hasTimedSpan(_ node: LyricsXMLNode) throws -> Bool {
            for span in node.descendants(localName: "span") where try timeMs(span.attribute("begin")) != nil { return true }
            return false
        }

        /// Character data of a node and its descendants, without background spans.
        static func textContent(_ node: LyricsXMLNode) -> String {
            var out = ""
            for child in node.children {
                switch child.kind {
                case .text, .cdata: out += child.text
                case .other: continue
                case .element:
                    if child.localName.lowercased() == "br" { out += " "; continue }
                    if attributeValue(child, "role")?.lowercased() == "x-bg" { continue }
                    out += textContent(child)
                }
            }
            return out
        }

        /// An attribute by local name, whatever its prefix (`ttm:agent`, `lrc:key`, `itunes:key`, `xml:lang`…).
        func attribute(_ node: LyricsXMLNode, _ localName: String) -> String? { Self.attributeValue(node, localName) }

        static func attributeValue(_ node: LyricsXMLNode, _ localName: String) -> String? {
            for attribute in node.attributes {
                let local = attribute.name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)
                if local == localName {
                    let value = ParseKit.trim(attribute.value)
                    return value.isEmpty ? nil : value
                }
            }
            return nil
        }

        // MARK: Untimed documents

        func plainLyrics(_ paragraphs: [Paragraph]) -> Lyrics? {
            let lines = paragraphs.flatMap { p in [p.lead] + p.backgrounds }.map { ParseKit.trim($0.plainText) }
                .filter { !ParseKit.isBlank($0) }
            if lines.isEmpty { return nil }
            let hasKana = lines.contains(where: Self.containsKana)
            let plain = lines.map { line -> String in
                guard let romanized = LyricsUtils.romanize(line, entireLyricsHasKana: hasKana, provider: romanization),
                      !romanized.isEmpty else { return line }
                return line + "\n" + romanized
            }
            return Lyrics(plain: plain, areFromRemote: true)
        }

        // MARK: Timed documents

        func timedLyrics(_ paragraphs: [Paragraph], bodyDurationMs: Int64?) -> Lyrics? {
            let voices = voiceIds(paragraphs)
            var built: [BuiltLine] = []
            for (index, paragraph) in paragraphs.enumerated() {
                let voice = voices[index]
                if let lead = Self.line(paragraph.lead, voiceId: voice, paragraph: index, isBackground: false) {
                    built.append(lead)
                }
                for background in paragraph.backgrounds {
                    guard let stripped = Self.strippingWrappingParentheses(background),
                          var line = Self.line(stripped, voiceId: backgroundVoiceId, paragraph: index, isBackground: true)
                    else { continue }
                    // A background part without its own times sings within its paragraph.
                    if line.endMs == nil { line.endMs = paragraph.lead.endMs }
                    built.append(line)
                }
            }
            if built.isEmpty { return nil }

            // Stable sort by start; lines without an end end where the next line starts, else at the body's `dur`.
            built = PreparedText.stableSorted(built, by: \.startMs)
            var lines: [TimedLine] = []
            lines.reserveCapacity(built.count)
            for (i, line) in built.enumerated() {
                var end = line.endMs
                if end == nil {
                    end = built[(i + 1)...].first { $0.startMs > line.startMs }?.startMs ?? bodyDurationMs
                }
                guard let lineEnd = end, lineEnd > line.startMs else { return nil }
                lines.append(TimedLine(startMs: line.startMs, endMs: lineEnd, text: line.text, voiceId: line.voiceId,
                                       syllables: line.syllables))
            }
            let usedVoices = Set(lines.map(\.voiceId))
            var docVoices = [Voice(id: leadVoiceId, role: VoiceRole.lead)]
            if usedVoices.contains(duetVoiceId) { docVoices.append(Voice(id: duetVoiceId, role: VoiceRole.duet)) }
            if usedVoices.contains(backgroundVoiceId) {
                docVoices.append(Voice(id: backgroundVoiceId, role: VoiceRole.background))
            }
            var docMetadata = metadata
            docMetadata.durationMs = nil
            let doc = LyricsDoc(metadata: docMetadata, voices: docVoices, lines: lines)
            guard LyricsDocCodec.isValid(doc) else { return nil }

            var lyrics = doc.toLyrics()
            lyrics.areFromRemote = true
            attachExtras(&lyrics, built: built, paragraphs: paragraphs)
            return lyrics
        }

        /// The voice of each paragraph: the first person agent that sings a line is the lead; other people are
        /// the duet voice; groups and lines without an agent are the lead.
        func voiceIds(_ paragraphs: [Paragraph]) -> [String] {
            var types: [String: String] = [:]
            for agent in root.descendants(localName: "agent") {
                guard let id = attribute(agent, "id") else { continue }
                types[id] = attribute(agent, "type")?.lowercased() ?? "person"
            }
            func isGroup(_ agent: String) -> Bool { types[agent].map { $0 == "group" } ?? false }
            let lead = paragraphs.lazy.compactMap(\.agent).first { !isGroup($0) }
            return paragraphs.map { paragraph in
                guard let agent = paragraph.agent, let lead, !isGroup(agent), !agent.isIdentical(to: lead) else {
                    return leadVoiceId
                }
                return duetVoiceId
            }
        }

        /// A line from its pieces: untimed text joins the neighbouring timed piece; the line spans its paragraph
        /// times and its syllables. nil for blank or untimed lines.
        static func line(_ collector: Collector, voiceId: String, paragraph: Int, isBackground: Bool) -> BuiltLine? {
            var pieces = collector.pieces
            if pieces.isEmpty { return nil }
            let timedCount = pieces.count { $0.beginMs != nil }
            if timedCount == 0 {
                guard let begin = collector.beginMs else { return nil }
                let text = collector.plainText
                if ParseKit.isBlank(text) { return nil }
                return BuiltLine(startMs: begin, endMs: collector.endMs, text: text, voiceId: voiceId, syllables: [],
                                 paragraph: paragraph, isBackground: isBackground)
            }

            // Fold untimed pieces into the previous timed piece (or the next one at the start of the line).
            var merged: [Piece] = []
            var carried: Piece?
            for piece in pieces {
                if piece.beginMs == nil {
                    if var last = merged.popLast() {
                        last.text += (piece.startsWord ? " " : "") + piece.text
                        merged.append(last)
                    } else if var pending = carried {
                        pending.text += (piece.startsWord ? " " : "") + piece.text
                        carried = pending
                    } else {
                        carried = piece
                    }
                    continue
                }
                var timed = piece
                if let pending = carried {
                    timed.text = pending.text + (piece.startsWord ? " " : "") + piece.text
                    timed.startsWord = true
                    carried = nil
                }
                merged.append(timed)
            }
            pieces = merged

            // Syllable texts keep the space that ends their word, so they join to the line text exactly.
            var texts = pieces.map(\.text)
            for i in pieces.indices.dropFirst() where pieces[i].startsWord { texts[i - 1] += " " }

            var syllables: [TimedSyllable] = []
            syllables.reserveCapacity(pieces.count)
            var previousStart: Int64 = 0
            for (i, piece) in pieces.enumerated() {
                let start = Swift.max(piece.beginMs ?? 0, previousStart)
                let nextBegin = pieces[(i + 1)...].lazy.compactMap(\.beginMs).first
                let end = piece.endMs ?? nextBegin ?? collector.endMs ?? start
                syllables.append(TimedSyllable(startMs: start, durationMs: Swift.max(end - start, 1), text: texts[i]))
                previousStart = start
            }
            let firstStart = syllables[0].startMs
            let lastEnd = syllables.map { $0.startMs + $0.durationMs }.max() ?? firstStart + 1
            let startMs = Swift.min(collector.beginMs ?? firstStart, firstStart)
            let endMs = Swift.max(collector.endMs ?? lastEnd, lastEnd)
            let text = texts.joined()
            if ParseKit.isBlank(text) { return nil }
            return BuiltLine(startMs: startMs, endMs: endMs, text: text, voiceId: voiceId, syllables: syllables,
                             paragraph: paragraph, isBackground: isBackground)
        }

        /// `(oh yeah)` → `oh yeah` when one pair of parentheses wraps the whole background part.
        static func strippingWrappingParentheses(_ collector: Collector) -> Collector? {
            var c = collector
            let text = Array(c.plainText.unicodeScalars)
            guard text.count >= 2, text.first == "(", text.last == ")" else { return c }
            var depth = 0
            for (i, scalar) in text.enumerated() {
                if scalar == "(" { depth += 1 }
                if scalar == ")" { depth -= 1 }
                if depth == 0 && i < text.count - 1 { return c } // the first "(" closes before the end
            }
            c.pieces[0].text = String(c.pieces[0].text.unicodeScalars.dropFirst())
            let last = c.pieces.count - 1
            c.pieces[last].text = String(c.pieces[last].text.unicodeScalars.dropLast())
            c.pieces = c.pieces.filter { !ParseKit.isBlank($0.text) }.map { piece in
                var trimmed = piece
                trimmed.text = ParseKit.trim(piece.text)
                return trimmed
            }
            if c.pieces.isEmpty { return nil }
            c.pieces[0].startsWord = true
            return c
        }

        // MARK: Translations and romanisation

        /// Each lead line's translation (head, else inline) and romanisation (head transliteration, else inline,
        /// else on-device), plus the plain text `LyricsUtils.parseLyrics` would build.
        func attachExtras(_ lyrics: inout Lyrics, built: [BuiltLine], paragraphs: [Paragraph]) {
            guard var synced = lyrics.synced, synced.count == built.count else { return }
            let translations = headTexts(elementName: "translation", preferringTranslation: true)
            let transliterations = headTexts(elementName: "transliteration", preferringTranslation: false)
            let hasKana = synced.contains { Self.containsKana($0.line) }
            for i in synced.indices {
                let source = built[i]
                let paragraph = paragraphs[source.paragraph]
                if !source.isBackground {
                    let translation = paragraph.key.flatMap { translations[$0] }
                        ?? Self.cleaned(paragraph.extras.inlineTranslation.joined(separator: " "))
                    synced[i].translation = translation.flatMap { Self.differs($0, from: synced[i].line) ? $0 : nil }
                    let roman = paragraph.key.flatMap { transliterations[$0] }
                        ?? Self.cleaned(paragraph.extras.inlineRomanization.joined(separator: " "))
                    if let roman, Self.differs(roman, from: synced[i].line) {
                        synced[i].romanization = roman
                        continue
                    }
                }
                synced[i].romanization = LyricsUtils.romanize(synced[i].line, entireLyricsHasKana: hasKana,
                                                              provider: romanization)
            }
            lyrics.synced = synced
            lyrics.plain = synced.map { line in
                var out = line.line
                if let r = line.romanization, !r.isEmpty { out += "\n" + r }
                if let t = line.translation, !t.isEmpty { out += "\n" + t }
                return out
            }
        }

        /// `key → text` of one head translation/transliteration (the best language for the reader).
        func headTexts(elementName: String, preferringTranslation: Bool) -> [String: String] {
            let lyricsLanguage = attribute(root, "lang").map(Self.primaryLanguage)
            let sets = root.descendants(localName: elementName).filter { set in
                // A translation into the lyrics' own language adds nothing.
                guard preferringTranslation, let lyricsLanguage, let lang = attribute(set, "lang") else { return true }
                return Self.primaryLanguage(lang) != lyricsLanguage
            }
            guard !sets.isEmpty else { return [:] }
            var chosen = sets[0]
            if preferringTranslation {
                outer: for preferred in preferredLanguages.map(Self.primaryLanguage) {
                    for set in sets where attribute(set, "lang").map(Self.primaryLanguage) == preferred {
                        chosen = set
                        break outer
                    }
                }
            }
            var out: [String: String] = [:]
            for text in chosen.descendants(localName: "text") {
                guard let key = attribute(text, "for"), out[key] == nil,
                      let value = Self.cleaned(Self.textContent(text)) else { continue }
                out[key] = value
            }
            return out
        }

        static func cleaned(_ raw: String) -> String? {
            let text = ParseKit.trim(TtmlLyricsParser.replaceRegexSpaceRuns(TtmlLyricsParser.sanitizeTextFragment(raw)))
            return ParseKit.isBlank(text) ? nil : text
        }

        static func differs(_ extra: String, from line: String) -> Bool {
            !LrcLibMatching.normalizeForMatch(extra).isIdentical(to: LrcLibMatching.normalizeForMatch(line))
        }

        static func primaryLanguage(_ tag: String) -> String {
            String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
        }

        static func containsKana(_ text: String) -> Bool {
            text.utf16.contains { (0x3040...0x309F).contains($0) || (0x30A0...0x30FF).contains($0) }
        }
    }
}
