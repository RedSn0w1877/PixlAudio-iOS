// Port of `presentation/lyrics/model/PreparedLyricsBuilder.kt`: builds the immutable `PreparedLyrics` model (spec §6.1)
// from `Lyrics` / `LyricsDoc` / `SyncedLine`. Pure and allocation-heavy by design: run it off the main thread, once
// per lyrics change.
//
// Source preference: `Lyrics.document` when present (explicit syllable durations, voices and line ends), otherwise
// `Lyrics.synced` with `SyncedWord.startsNewWord` for word grouping.
//
// Text is handled as UTF-16 code units throughout so syllable ranges match Android's Kotlin indices exactly.
// Millisecond arithmetic wraps like Kotlin's `Long` (`&+`) instead of trapping on hostile input.

import Foundation
import PixlFoundation
import PixlModel

/// Builds `PreparedLyrics`.
public enum PreparedLyricsBuilder {

    /// A gap at least this long between two groups gets interlude dots (Apple web value).
    public static let interludeMinGapMs: Int64 = 9_000

    /// A background vocal joins the lead whose `[start - this, end]` window holds its start.
    public static let backgroundGroupLeadInMs: Int64 = 1_000

    /// Inferred end of a line's final syllable: at most this long after it starts.
    public static let lastSyllableMaxMs: Int64 = 1_200

    /// The final line of a song stays active at least this long when its end is inferred.
    public static let lastLineMinMs: Int64 = 4_000

    /// Emphasis ("glow") needs a word held at least this long, with an explicit end.
    public static let emphasisMinDurationMs: Int64 = 1_000
    public static let emphasisMinGraphemes = 2
    public static let emphasisMaxGraphemes = 7

    /// Returns nil when there is nothing time-synced to show (plain lyrics or none at all).
    public static func build(_ lyrics: Lyrics?) -> PreparedLyrics? {
        guard let lyrics else { return nil }
        if let doc = lyrics.document, doc.lines.contains(where: { !$0.text.isKotlinBlank }) {
            return buildFromDoc(doc, lyrics.synced)
        }
        guard let synced = lyrics.synced, !synced.isEmpty else { return nil }
        return buildFromSynced(synced)
    }

    public static func build(_ doc: LyricsDoc) -> PreparedLyrics? { buildFromDoc(doc, nil) }

    // MARK: - Drafts: mutable working copies, frozen into Prepared* at the end.

    final class DraftSyllable {
        let charStart: Int
        let charEnd: Int
        let startMs: Int64
        var endMs: Int64
        let endIsExplicit: Bool
        /// True when this syllable begins a new word (whitespace or a CJK boundary before it).
        let startsWord: Bool
        var wordIndex = 0
        var emphasis = false

        init(charStart: Int, charEnd: Int, startMs: Int64, endMs: Int64, endIsExplicit: Bool, startsWord: Bool) {
            self.charStart = charStart
            self.charEnd = charEnd
            self.startMs = startMs
            self.endMs = endMs
            self.endIsExplicit = endIsExplicit
            self.startsWord = startsWord
        }
    }

    final class DraftLine {
        let startMs: Int64
        var endMs: Int64
        var endIsExplicit: Bool
        let text: String
        let role: PreparedVoiceRole
        let syllables: [DraftSyllable]?
        let translation: String?
        let romanization: String?
        /// Only for the LRC path: the source line, for `resolveLineEndTimeMs`.
        let source: SyncedLine?
        /// Only for the LRC path: end set by a following empty LRC line.
        var markerEndMs: Int64?
        var estimatedEndMs: Int64 = 0
        var groupLead = -1
        var bgAbove = false

        init(startMs: Int64, endMs: Int64, endIsExplicit: Bool, text: String, role: PreparedVoiceRole,
             syllables: [DraftSyllable]?, translation: String?, romanization: String?, source: SyncedLine? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.endIsExplicit = endIsExplicit
            self.text = text
            self.role = role
            self.syllables = syllables
            self.translation = translation
            self.romanization = romanization
            self.source = source
        }
    }

    // MARK: - LyricsDoc path

    static func buildFromDoc(_ doc: LyricsDoc, _ synced: [SyncedLine]?) -> PreparedLyrics? {
        var extrasByStart: [Int64: SyncedLine] = [:]
        synced?.forEach { line in
            let key = Int64(line.time)
            if extrasByStart[key] == nil { extrasByStart[key] = line }
        }

        var drafts: [DraftLine] = []
        drafts.reserveCapacity(doc.lines.count)
        // Stable, so lines sharing a start keep their document order.
        for line in PreparedText.stableSorted(doc.lines, by: \.startMs) {
            if line.text.isKotlinBlank { continue }
            let role = PreparedVoiceRole.fromRole(doc.voices.first { $0.id.isIdentical(to: line.voiceId) }?.role)
            let lineUnits = PreparedText.units(line.text)
            let first = PreparedText.firstNonWhitespace(lineUnits)
            let last = PreparedText.lastNonWhitespace(lineUnits)
            let textUnits = Array(lineUnits[first...last])
            let text = PreparedText.string(textUnits[...])
            let textLength = textUnits.count

            var syllables: [DraftSyllable]?
            if !line.syllables.isEmpty {
                var out: [DraftSyllable] = []
                out.reserveCapacity(line.syllables.count)
                var offset = 0
                var boundary = true
                // Document order: the syllable texts concatenate to the line text, in order.
                for s in line.syllables {
                    let sUnits = PreparedText.units(s.text)
                    let rawStart = offset
                    offset += sUnits.count
                    let lead = PreparedText.firstNonWhitespace(sUnits)
                    if lead < 0 { // whitespace-only token: a word boundary, nothing to time
                        boundary = true
                        continue
                    }
                    let trail = PreparedText.lastNonWhitespace(sUnits)
                    let cs = (rawStart + lead - first).coerced(in: 0, textLength)
                    let ce = (rawStart + trail + 1 - first).coerced(in: 0, textLength)
                    let startsWord = out.isEmpty || boundary || lead > 0 || PreparedText.isCjk(sUnits[lead])
                    boundary = trail < sUnits.count - 1
                    if ce <= cs { continue }
                    out.append(DraftSyllable(
                        charStart: cs,
                        charEnd: ce,
                        startMs: s.startMs,
                        endMs: s.startMs &+ Swift.max(s.durationMs, 1),
                        endIsExplicit: s.durationMs > 0,
                        startsWord: startsWord
                    ))
                }
                syllables = out.isEmpty ? nil : out
            }

            let extras = extrasByStart[line.startMs]
            drafts.append(DraftLine(
                startMs: line.startMs,
                endMs: Swift.max(line.endMs, line.startMs &+ 1),
                endIsExplicit: line.endMs > line.startMs,
                text: text,
                role: role,
                syllables: syllables,
                translation: extras?.translation.flatMap { $0.isKotlinBlank ? nil : $0 },
                romanization: extras?.romanization.flatMap { $0.isKotlinBlank ? nil : $0 }
            ))
        }
        if drafts.isEmpty { return nil }
        return finish(drafts)
    }

    // MARK: - SyncedLine (LRC / enhanced LRC / transpiled) path

    static func buildFromSynced(_ synced: [SyncedLine]) -> PreparedLyrics? {
        var drafts: [DraftLine] = []
        drafts.reserveCapacity(synced.count)
        for line in PreparedText.stableSorted(synced, by: \.time) {
            let text = LyricsSheetLogic.sanitizeLyricLineText(line.line).kotlinTrimmedEnd()
            let words = line.words.map(LyricsSheetLogic.sanitizeSyncedWords) ?? []
            if text.isKotlinBlank && words.isEmpty {
                // An empty LRC line is the explicit end of the line before it.
                if let previous = drafts.last, Int64(line.time) > previous.startMs, previous.markerEndMs == nil {
                    previous.markerEndMs = Int64(line.time)
                }
                continue
            }

            let (lineText, syllables) = mapWordsIntoText(text, words)
            drafts.append(DraftLine(
                startMs: Int64(line.time),
                endMs: 0, // resolved below, once every start is known
                endIsExplicit: false,
                text: lineText,
                role: PreparedVoiceRole.fromRole(line.voiceRole),
                syllables: syllables,
                translation: line.translation.flatMap { $0.isKotlinBlank ? nil : $0 },
                romanization: line.romanization.flatMap { $0.isKotlinBlank ? nil : $0 },
                source: line
            ))
        }
        if drafts.isEmpty { return nil }

        for i in drafts.indices {
            let d = drafts[i]
            guard let src = d.source else { continue }
            let explicitLineEnd: Int64? = src.endTime.flatMap { $0 > src.time ? Int64($0) : nil }
            if let explicitLineEnd {
                d.endMs = explicitLineEnd
                d.endIsExplicit = true
            } else if let marker = d.markerEndMs {
                d.endMs = marker
                d.endIsExplicit = true
            } else {
                var nextLeadStart: Int64?
                var j = i + 1
                while j < drafts.count {
                    if drafts[j].role != .background && drafts[j].startMs > d.startMs {
                        nextLeadStart = drafts[j].startMs
                        break
                    }
                    j += 1
                }
                let maxExplicitSyllableEnd = d.syllables?.filter(\.endIsExplicit).map(\.endMs).max() ?? 0
                let inferred: Int64
                if let nextLeadStart {
                    let next = Int(Int32(truncatingIfNeeded: Swift.min(nextLeadStart, Int64(Int32.max))))
                    inferred = LyricsSheetLogic.resolveLineEndTimeMs(src, nextLineStartMs: next)
                } else {
                    let lastSyllableStart = d.syllables?.map(\.startMs).max() ?? d.startMs
                    inferred = Swift.max(
                        d.startMs &+ Swift.max(lastLineMinMs, estimatedDurationMs(d)),
                        lastSyllableStart &+ 1
                    )
                }
                d.endMs = Swift.max(inferred, maxExplicitSyllableEnd, d.startMs &+ 1)
                d.endIsExplicit = false
            }
        }
        return finish(drafts)
    }

    /// Finds each (trimmed) word inside `text` in order, so the syllable ranges index into the line exactly as the
    /// source wrote it. If the words cannot be found (the line text and the word tokens disagree), the line text is
    /// rebuilt from the words instead.
    static func mapWordsIntoText(_ text: String, _ words: [SyncedWord]) -> (String, [DraftSyllable]?) {
        if words.isEmpty { return (text, nil) }
        let clusters = LyricsSheetLogic.clusterSyncedWords(words)
        var startsWord = [Bool](repeating: false, count: words.count)
        for cluster in clusters { startsWord[cluster.startIndex] = true }

        let textUnits = PreparedText.units(text)
        var ranges = [Int](repeating: 0, count: words.count * 2)
        var cursor = 0
        var found = true
        for (k, w) in words.enumerated() {
            let wUnits = PreparedText.units(w.word)
            let at = PreparedText.indexOf(textUnits, wUnits, from: cursor)
            if at < 0 { found = false; break }
            ranges[2 * k] = at
            ranges[2 * k + 1] = at + wUnits.count
            cursor = at + wUnits.count
        }
        var lineText = text
        if !found {
            var built: [UInt16] = []
            for (k, w) in words.enumerated() {
                if k > 0 && w.startsNewWord { built.append(0x20) }
                ranges[2 * k] = built.count
                built.append(contentsOf: w.word.utf16)
                ranges[2 * k + 1] = built.count
            }
            lineText = PreparedText.string(built[...])
        }

        var out: [DraftSyllable] = []
        out.reserveCapacity(words.count)
        for (k, w) in words.enumerated() {
            let explicitEnd: Int64? = w.endTime.flatMap { $0 > w.time ? Int64($0) : nil }
            out.append(DraftSyllable(
                charStart: ranges[2 * k],
                charEnd: ranges[2 * k + 1],
                startMs: Int64(w.time),
                endMs: explicitEnd ?? 0, // inferred ends are filled in by finish()
                endIsExplicit: explicitEnd != nil,
                startsWord: startsWord[k]
            ))
        }
        return (lineText, out)
    }

    // MARK: - Shared: estimates, grouping, interludes, syllable ends, emphasis, freeze.

    static func finish(_ drafts: [DraftLine]) -> PreparedLyrics {
        // Syllable ends that depend only on the next syllable (the last one needs the line end).
        for d in drafts { if let s = d.syllables { inferInnerSyllableEnds(s) } }

        for d in drafts { d.estimatedEndMs = estimatedEndMs(d) }
        groupBackgroundVocals(drafts)

        let leaders = drafts.indices.filter { drafts[$0].groupLead == $0 }
        var members: [Int: [Int]] = [:]
        for i in drafts.indices {
            let lead = drafts[i].groupLead
            if lead != i { members[lead, default: []].append(i) }
        }

        var rows: [PreparedRow] = []
        rows.reserveCapacity(drafts.count + 4)
        var interludes: [(Int64, Int64)] = []
        var prevEnd: Int64 = 0
        for leader in leaders {
            let group = members[leader] ?? []
            let groupStart = group.reduce(drafts[leader].startMs) { Swift.min($0, drafts[$1].startMs) }
            // prevEnd is 0 before the first group, so this also catches an intro of >= 9 s.
            if groupStart &- prevEnd >= interludeMinGapMs {
                rows.append(.interlude(startMs: prevEnd, endMs: groupStart, alignEnd: drafts[leader].role == .duet))
                interludes.append((prevEnd, groupStart))
            }
            for i in group where drafts[i].bgAbove { rows.append(.line(lineIndex: i)) }
            rows.append(.line(lineIndex: leader))
            for i in group where !drafts[i].bgAbove { rows.append(.line(lineIndex: i)) }

            prevEnd = Swift.max(prevEnd, drafts[leader].estimatedEndMs)
            for i in group { prevEnd = Swift.max(prevEnd, drafts[i].estimatedEndMs) }
        }

        // A line whose end was only inferred must not stay active into the interlude after it.
        if !interludes.isEmpty {
            for d in drafts where !d.endIsExplicit {
                for gap in interludes {
                    let g0 = gap.0
                    if d.startMs < g0 && d.endMs > g0 { d.endMs = Swift.max(g0, d.startMs &+ 1) }
                }
            }
        }

        for d in drafts {
            guard let syllables = d.syllables else { continue }
            inferLastSyllableEnd(syllables, d.endMs)
            assignWordIndices(syllables)
            markEmphasis(d.text, syllables)
        }

        let lines = drafts.enumerated().map { i, d in
            PreparedLine(
                index: i,
                startMs: d.startMs,
                endMs: d.endMs,
                endIsExplicit: d.endIsExplicit,
                text: d.text,
                role: d.role,
                groupLeadIndex: d.groupLead,
                bgAbove: d.groupLead != i && d.bgAbove,
                syllables: d.syllables?.map { s in
                    PreparedSyllable(
                        charStart: s.charStart,
                        charEnd: s.charEnd,
                        startMs: s.startMs,
                        endMs: s.endMs,
                        endIsExplicit: s.endIsExplicit,
                        wordIndex: s.wordIndex,
                        emphasis: s.emphasis
                    )
                },
                translation: d.translation,
                romanization: d.romanization
            )
        }

        return PreparedLyrics(
            lines: lines,
            rows: rows,
            hasWordTiming: lines.contains { $0.hasWordTiming },
            hasDuet: lines.contains { $0.role == .duet },
            startsSorted: lines.map(\.startMs)
        )
    }

    /// Explicit ends stay; otherwise a syllable ends where the next one starts.
    static func inferInnerSyllableEnds(_ syllables: [DraftSyllable]) {
        guard syllables.count > 1 else { return }
        for k in 0..<(syllables.count - 1) {
            let s = syllables[k]
            if !s.endIsExplicit { s.endMs = Swift.max(syllables[k + 1].startMs, s.startMs &+ 1) }
        }
    }

    /// The last syllable's inferred end: `min(lineEnd, start + 1200)`.
    static func inferLastSyllableEnd(_ syllables: [DraftSyllable], _ lineEndMs: Int64) {
        guard let last = syllables.last else { return }
        if !last.endIsExplicit {
            last.endMs = Swift.max(Swift.min(lineEndMs, last.startMs &+ lastSyllableMaxMs), last.startMs &+ 1)
        }
    }

    static func assignWordIndices(_ syllables: [DraftSyllable]) {
        var word = -1
        for (k, s) in syllables.enumerated() {
            if k == 0 || s.startsWord { word += 1 }
            s.wordIndex = word
        }
    }

    /// §1.4: a word glows when its **explicit** duration is ≥ 1000 ms and its trimmed length is 2–7 graphemes
    /// (CJK: duration only). Syllables with `startsNewWord == false` are merged into one word first.
    static func markEmphasis(_ text: String, _ syllables: [DraftSyllable]) {
        var k = 0
        while k < syllables.count {
            var end = k
            while end + 1 < syllables.count && syllables[end + 1].wordIndex == syllables[k].wordIndex { end += 1 }
            let first = syllables[k]
            let last = syllables[end]
            let explicit = (k...end).allSatisfy { syllables[$0].endIsExplicit }
            let durationMs = last.endMs &- first.startMs
            let word = PreparedText.substring(text, first.charStart, Swift.max(last.charEnd, first.charStart))
                .kotlinTrimmed()
            let qualifies = explicit && durationMs >= emphasisMinDurationMs && !word.isEmpty
                && (word.utf16.contains(where: PreparedText.isCjk)
                    || (emphasisMinGraphemes...emphasisMaxGraphemes).contains(graphemeCount(word)))
            if qualifies { for i in k...end { syllables[i].emphasis = true } }
            k = end + 1
        }
    }

    /// §1.7: a background vocal belongs to the lead line whose `[start - 1000, end]` window holds its start. A lead
    /// already playing when the vocal starts wins over one about to start.
    static func groupBackgroundVocals(_ drafts: [DraftLine]) {
        for (i, d) in drafts.enumerated() {
            d.groupLead = i
            d.bgAbove = false
        }
        for d in drafts where d.role == .background {
            var playing = -1
            var upcoming = -1
            for (j, lead) in drafts.enumerated() where lead.role != .background {
                let inWindow = d.startMs >= lead.startMs &- backgroundGroupLeadInMs && d.startMs <= lead.endMs
                if !inWindow { continue }
                if lead.startMs <= d.startMs {
                    if playing < 0 || lead.startMs >= drafts[playing].startMs { playing = j }
                } else if upcoming < 0 {
                    upcoming = j
                }
            }
            let lead = playing >= 0 ? playing : upcoming
            if lead >= 0 {
                d.groupLead = lead
                d.bgAbove = d.startMs < drafts[lead].startMs
            }
        }
    }

    /// Estimated end used for interlude detection: the explicit end when there is one, otherwise
    /// `start + clamp(words × 450 + 800, 1500, 6000)` — but never before the last syllable could plausibly finish,
    /// and never after the resolved end.
    static func estimatedEndMs(_ d: DraftLine) -> Int64 {
        if d.endIsExplicit { return d.endMs }
        let base = d.startMs &+ estimatedDurationMs(d)
        let syllableFloor = d.syllables?.map { s in
            s.endIsExplicit ? s.endMs : s.startMs &+ lastSyllableMaxMs
        }.max() ?? 0
        return Swift.max(Swift.min(d.endMs, Swift.max(base, syllableFloor)), d.startMs &+ 1)
    }

    static func estimatedDurationMs(_ d: DraftLine) -> Int64 {
        let words: Int
        if let syl = d.syllables {
            words = Swift.max(syl.reduce(0) { $0 + ($1.startsWord ? 1 : 0) }, 1)
        } else {
            words = estimateWordCount(d.text)
        }
        return (Int64(words) &* 450 &+ 800).coerced(in: 1_500, 6_000)
    }

    /// `estimateWordCount`: every CJK character is a word; other runs of non-whitespace are one word each.
    public static func estimateWordCount(_ text: String) -> Int { TextSegmentation.estimateWordCount(text) }

    /// `graphemeCount` (`BreakIterator.getCharacterInstance()` = extended grapheme clusters).
    public static func graphemeCount(_ text: String) -> Int { TextSegmentation.graphemeCount(text) }
}
