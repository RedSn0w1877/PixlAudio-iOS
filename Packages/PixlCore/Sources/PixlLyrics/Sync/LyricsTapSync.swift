// "Sync it yourself" — the pure core of the tap-to-sync lyrics editor, ported line for line from the Android
// `data/lyrics/sync/LyricsTapSync.kt`.
//
// Everything here is plain Swift: no player, no UI, no clocks. The editor feeds it positions and taps, gets back a
// new immutable draft plus an optional seek target, and asks it for the finished `LyricsDoc`. See `SyncModel.swift`
// for the raw/built time domains.
//
// Kotlin semantics kept on purpose: `Long` arithmetic wraps (`&+`, `&-`, `&*`) instead of trapping, strings compare
// by code unit (`isIdentical(to:)`), whitespace is Kotlin's `isWhitespace`, and lengths are UTF-16 where Android
// uses `String.length`.

import Foundation
import PixlFoundation
import PixlModel

/// Tokenisation, draft building, the tap/undo/rewind reducers and the finished document.
public enum LyricsTapSync {

    public static let leadVoiceId = "lead"
    public static let sourceUser = "user"

    /// A pointer held at least this long counts as "held"; its release stamps the word end.
    public static let holdThresholdMs: Int64 = 350
    /// A second tap this soon after the previous one is a bounce and is ignored.
    public static let bounceMs: Int64 = 60
    /// Undo presses closer than this are batched; only the last seek runs.
    public static let undoBatchWindowMs: Int64 = 300
    public static let undoSeekDelayMs: Int64 = 250

    public static let minTapGapMs: Int64 = 10
    public static let minWordMs: Int64 = 40
    public static let defaultGapMs: Int64 = 450
    public static let sustainGapMs: Int64 = 4_000
    public static let undoPrerollMs: Int64 = 2_000
    public static let anchorPrerollMs: Int64 = 3_000
    public static let fixLinePrerollMs: Int64 = 2_500
    public static let rewindMs: Int64 = 5_000
    public static let earlyTapMs: Int64 = 3_000
    public static let nextLineGuardMs: Int64 = 40
    public static let roughWordMaxMs: Int64 = 600
    public static let tailMarginMs: Int64 = 500
    public static let nudgeStepMs = 20
    public static let maxNudgeMs = 400
    public static let maxOffsetMs = 400
    public static let defaultOffsetSpeakerMs = 100
    public static let defaultOffsetBluetoothMs = 180
    public static let maxChunkChars = 40

    static let maxDocDurationMs: Int64 = 86_400_000
    static let minKnownDurationMs: Int64 = 1_000
    static let maxVoices = 32
    static let voiceRoles: [String] = [VoiceRole.lead, VoiceRole.background, VoiceRole.duet]

    /// `it in VOICE_ROLES`, comparing by code unit like Kotlin.
    static func isVoiceRole(_ role: String) -> Bool { voiceRoles.contains { $0.isIdentical(to: role) } }

    // MARK: - Tokenisation

    /// Small kana, prolonged-sound and iteration marks: sung together with the character before.
    static let cjkAttaching: Set<UInt32> = {
        var set: Set<UInt32> = [
            0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096, 0x30A1, 0x30A3,
            0x30A5, 0x30A7, 0x30A9, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FC, 0x309D, 0x309E, 0x30FD,
            0x30FE, 0x309B, 0x309C, 0xFF67, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B, 0xFF6C, 0xFF6D, 0xFF6E, 0xFF70, 0xFF9E,
            0xFF9F,
        ]
        for cp in UInt32(0x31F0)...0x31FF { set.insert(cp) } // Katakana phonetic extensions (small ㇰ…ㇿ)
        return set
    }()

    /// Trims and collapses every run of whitespace (any Unicode space) to a single space.
    public static func normalizeLine(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in line.unicodeScalars {
            if TextScripts.isKotlinWhitespace(scalar) {
                if !out.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    /// Splits a lyric line into tappable tokens. `tokenize(x).joined() == normalizeLine(x)` always holds (by code
    /// unit), which is what `LyricsDocCodec.isValid` needs.
    ///
    /// - Words are split on spaces and keep their trailing space (except the last).
    /// - Punctuation-only chunks (`-`, `—`, `…`, `&`) join the previous word (or the next one when first).
    /// - Hyphenated and apostrophe words stay whole.
    /// - Han / Hiragana / Katakana runs split into single graphemes; small kana and `ー` stay with the character
    ///   before; CJK punctuation joins the previous grapheme. Latin inside such a chunk stays whole.
    /// - Hangul, Thai and everything else split on spaces only. Chunks over 40 UTF-16 units stay whole.
    public static func tokenize(_ line: String) -> [String] {
        let normalized = normalizeLine(line)
        if normalized.isEmpty { return [] }
        // Split on U+0020 scalars, not Characters: a space followed by a combining mark is one Character.
        let chunks = normalized.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        var tokens: [String] = []
        tokens.reserveCapacity(chunks.count)
        var pendingPrefix = ""
        for (index, chunk) in chunks.enumerated() {
            let separator = index < chunks.count - 1 ? " " : ""
            if TextScripts.isPunctuationOnly(chunk) {
                if !tokens.isEmpty {
                    tokens[tokens.count - 1] += chunk + separator
                } else {
                    pendingPrefix += chunk + separator
                }
                continue
            }
            let pieces = splitChunk(chunk)
            for (pieceIndex, piece) in pieces.enumerated() {
                var text = piece
                if pieceIndex == 0 && !pendingPrefix.isEmpty {
                    text = pendingPrefix + text
                    pendingPrefix = ""
                }
                if pieceIndex == pieces.count - 1 { text += separator }
                tokens.append(text)
            }
        }
        if !pendingPrefix.isEmpty { tokens.append(pendingPrefix) }
        return tokens
    }

    private static func splitChunk(_ chunk: String) -> [String] {
        if chunk.utf16.count > maxChunkChars || !TextScripts.containsHanOrKana(chunk) { return [chunk] }
        var pieces: [String] = []
        var pieceIsCjk: [Bool] = []
        var run = ""
        func flushRun() {
            if !run.isEmpty {
                pieces.append(run)
                pieceIsCjk.append(false)
                run = ""
            }
        }
        for grapheme in graphemes(chunk) {
            let scalar = grapheme.unicodeScalars.first!
            let attaching = cjkAttaching.contains(scalar.value)
            if attaching && run.isEmpty && pieceIsCjk.last == true {
                pieces[pieces.count - 1] += grapheme
            } else if attaching || TextScripts.isHanOrKana(scalar) {
                flushRun()
                pieces.append(grapheme)
                pieceIsCjk.append(true)
            } else {
                run += grapheme
            }
        }
        flushRun()

        // Punctuation-only pieces (、。！？「」 and friends) join their neighbour.
        var merged: [String] = []
        merged.reserveCapacity(pieces.count)
        var prefix = ""
        for piece in pieces {
            if TextScripts.isPunctuationOnly(piece) {
                if !merged.isEmpty { merged[merged.count - 1] += piece } else { prefix += piece }
            } else {
                merged.append(prefix + piece)
                prefix = ""
            }
        }
        if !prefix.isEmpty { merged.append(prefix) }
        return merged
    }

    /// User-perceived characters. Emoji ZWJ sequences, modifiers and marks stay in one piece. Swift's `Character`
    /// is the extended grapheme cluster (`BreakIterator.getCharacterInstance`); the Android belt-and-braces merge
    /// is applied on top so edge cases (a ZWJ before a non-emoji, a mark after a control) match.
    static func graphemes(_ text: String) -> [String] {
        var out: [String] = []
        for character in text {
            let grapheme = String(character)
            if let last = out.last, continuesGrapheme(last, grapheme) {
                out[out.count - 1] += grapheme
            } else {
                out.append(grapheme)
            }
        }
        return out
    }

    private static func continuesGrapheme(_ previous: String, _ next: String) -> Bool {
        if previous.unicodeScalars.last?.value == 0x200D { return true }
        guard let scalar = next.unicodeScalars.first else { return false }
        let cp = scalar.value
        if cp == 0x200D || (0xFE00...0xFE0F).contains(cp) || (0xE0100...0xE01EF).contains(cp)
            || (0x1F3FB...0x1F3FF).contains(cp) || (0xE0020...0xE007F).contains(cp) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return true
        default: return false
        }
    }

    /// Character count of the trimmed text (code points), at least 1.
    static func weight(_ text: String) -> Int64 {
        Int64(max(1, text.kotlinTrimmed().unicodeScalars.count))
    }

    /// Starts for `texts` spread over `[fromMs, toMs)` in proportion to their character counts.
    static func spreadByChars(_ texts: [String], from fromMs: Int64, to toMs: Int64) -> [Int64] {
        let weights = texts.map(weight)
        let total = weights.reduce(0, &+).coerced(atLeast: 1)
        let span = (toMs &- fromMs).coerced(atLeast: 0)
        var accumulated: Int64 = 0
        return weights.map { w in
            let start = fromMs &+ span &* accumulated / total
            accumulated &+= w
            return start
        }
    }

    // MARK: - Building a draft

    /// `buildDraft(song, lyrics, pasted)`.
    public static func buildDraft(song: Song, lyrics: Lyrics?, pasted: String?) -> SyncDraftSeed {
        buildDraft(songId: song.id, title: song.title, artist: song.displayArtist, album: song.album,
                   durationMs: song.duration, lyrics: lyrics, pasted: pasted)
    }

    /// Turns whatever lyrics the song has into a draft (spec §3.2): pasted text → plain; a `LyricsDoc` → exact tokens
    /// from its syllables (user-synced or word-synced); word-synced `SyncedLine`s → exact tokens; line-synced →
    /// anchors; plain → no anchors.
    public static func buildDraft(songId: String, title: String, artist: String, album: String, durationMs: Int64,
                                  lyrics: Lyrics?, pasted: String?) -> SyncDraftSeed {
        var assembler = DraftAssembler()
        var voices: [Voice] = [Voice()]
        var duration = durationMs
        let origin: SyncDraftOrigin
        let document = lyrics?.document
        let synced = lyrics?.synced ?? []

        if let pasted {
            for line in kotlinLines(pasted) { assembler.addUntapped(tokenize(line)) }
            origin = .plain
        } else if let document, !document.lines.isEmpty {
            voices = document.voices
            if duration <= 0 { duration = document.metadata.durationMs ?? 0 }
            let hasWordTiming = addDocument(&assembler, document)
            if !hasWordTiming {
                origin = .lineSynced
            } else if document.metadata.source.map({ $0.isIdentical(to: sourceUser) }) == true {
                origin = .userSynced
            } else {
                origin = .wordSynced
            }
        } else if synced.contains(where: { !$0.line.isKotlinBlank || !($0.words ?? []).isEmpty }) {
            voices = addSynced(&assembler, synced)
            origin = synced.contains(where: { !($0.words ?? []).isEmpty }) ? .wordSynced : .lineSynced
        } else if let plain = lyrics?.plain, !plain.isEmpty {
            // parseLyrics appends romanization / translation after a '\n'; keep the original line only.
            for line in plain { assembler.addUntapped(tokenize(substringBeforeNewline(line))) }
            origin = .plain
        } else {
            return SyncDraftSeed(draft: nil, origin: .none)
        }

        if assembler.tokens.isEmpty { return SyncDraftSeed(draft: nil, origin: .none) }
        var draft = SyncDraft(songId: songId, durationMs: duration.coerced(atLeast: 0), lines: assembler.lines,
                              tokens: assembler.tokens, cursor: 0, voices: voices.isEmpty ? [Voice()] : voices,
                              title: title, artist: artist, album: album)
        let alreadyTimed = origin == .userSynced || origin == .wordSynced
        draft.cursor = alreadyTimed ? draft.tokens.count : nextTappable(draft, from: 0)
        return SyncDraftSeed(draft: draft, origin: origin)
    }

    private struct DraftAssembler {
        var lines: [SyncLine] = []
        var tokens: [SyncToken] = []

        mutating func addUntapped(_ texts: [String], voiceId: String = LyricsTapSync.leadVoiceId,
                                  anchorMs: Int64? = nil, translation: String? = nil) {
            addLine(texts.map { SyncToken(line: 0, text: $0) }, voiceId: voiceId, anchorMs: anchorMs,
                    translation: translation)
        }

        mutating func addLine(_ lineTokens: [SyncToken], voiceId: String, anchorMs: Int64?, translation: String?,
                              locked: Bool = false, skipped: Bool = false) {
            if lineTokens.isEmpty { return }
            let lineIndex = lines.count
            let first = tokens.count
            for token in lineTokens {
                var t = token
                t.line = lineIndex
                tokens.append(t)
            }
            lines.append(SyncLine(
                text: lineTokens.map(\.text).joined(),
                voiceId: voiceId,
                anchorMs: anchorMs?.coerced(atLeast: 0),
                translation: translation.flatMap { $0.isKotlinBlank ? nil : $0 },
                firstToken: first,
                tokenCount: lineTokens.count,
                locked: locked,
                skipped: skipped
            ))
        }

        /// Line with known start/end but no word timing: spread the words by character count.
        mutating func addSpread(_ texts: [String], voiceId: String, startMs: Int64, endMs: Int64,
                                translation: String?) {
            if texts.isEmpty { return }
            let end = max(startMs, endMs)
            let starts = LyricsTapSync.spreadByChars(texts, from: startMs, to: end)
            let lineTokens = texts.enumerated().map { k, text in
                SyncToken(line: 0, text: text, rawStartMs: starts[k],
                          rawEndMs: k < texts.count - 1 ? starts[k + 1] : end, exact: true)
            }
            addLine(lineTokens, voiceId: voiceId, anchorMs: startMs, translation: translation, skipped: true)
        }
    }

    /// Returns true when the document carried any word timing.
    private static func addDocument(_ assembler: inout DraftAssembler, _ doc: LyricsDoc) -> Bool {
        // `associate { it.id to it.role }`: the last voice with an id wins.
        func roleOf(_ id: String) -> String? { doc.voices.last { $0.id.isIdentical(to: id) }?.role }
        let hasWordTiming = doc.lines.contains { !$0.syllables.isEmpty }
        for line in doc.lines {
            let role = roleOf(line.voiceId) ?? VoiceRole.lead
            let syllables = mergeBlankSyllables(line.syllables)
            if !syllables.isEmpty {
                let lineTokens = syllables.map { s in
                    SyncToken(line: 0, text: s.text, rawStartMs: s.startMs, rawEndMs: s.startMs &+ s.durationMs,
                              exact: true)
                }
                assembler.addLine(lineTokens, voiceId: line.voiceId, anchorMs: line.startMs, translation: nil,
                                  locked: role.isIdentical(to: VoiceRole.background))
            } else {
                let texts = tokenize(line.text)
                if hasWordTiming {
                    assembler.addSpread(texts, voiceId: line.voiceId, startMs: line.startMs, endMs: line.endMs,
                                        translation: nil)
                } else {
                    assembler.addUntapped(texts, voiceId: line.voiceId, anchorMs: line.startMs)
                }
            }
        }
        return hasWordTiming
    }

    /// Whitespace-only syllables would be untappable: fold them into a neighbour.
    private static func mergeBlankSyllables(_ syllables: [TimedSyllable]) -> [TimedSyllable] {
        if !syllables.contains(where: { $0.text.isKotlinBlank }) { return syllables }
        var out: [TimedSyllable] = []
        out.reserveCapacity(syllables.count)
        var prefix = ""
        for s in syllables {
            if s.text.isKotlinBlank {
                if !out.isEmpty { out[out.count - 1].text += s.text } else { prefix += s.text }
                continue
            }
            if !prefix.isEmpty {
                var merged = s
                merged.text = prefix + s.text
                out.append(merged)
                prefix = ""
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Adds `Lyrics.synced` lines and returns the voices they use.
    private static func addSynced(_ assembler: inout DraftAssembler, _ allSynced: [SyncedLine]) -> [Voice] {
        let synced = allSynced.filter { !$0.line.isKotlinBlank || !($0.words ?? []).isEmpty }
        let anyWords = synced.contains { !($0.words ?? []).isEmpty }
        var usedRoles: [String] = []
        for (index, line) in synced.enumerated() {
            let role = isVoiceRole(line.voiceRole) ? line.voiceRole : VoiceRole.lead
            let words = (line.words ?? []).filter { !$0.word.isKotlinBlank }
            let before = assembler.lines.count
            if anyWords && !words.isEmpty {
                let lineTokens = words.enumerated().map { k, word -> SyncToken in
                    let next = k + 1 < words.count ? words[k + 1] : nil
                    return SyncToken(
                        line: 0,
                        text: word.word + (next != nil && next!.startsNewWord ? " " : ""),
                        rawStartMs: Int64(word.time).coerced(atLeast: 0),
                        rawEndMs: word.endTime.map { Int64($0) },
                        exact: true
                    )
                }
                assembler.addLine(lineTokens, voiceId: role, anchorMs: Int64(line.time),
                                  translation: line.translation, locked: role.isIdentical(to: VoiceRole.background))
            } else if anyWords {
                let texts = tokenize(line.line)
                let end = line.endTime.map { Int64($0) }
                    ?? (index + 1 < synced.count ? Int64(synced[index + 1].time) : nil)
                    ?? (Int64(line.time) &+ Int64(texts.count) &* defaultGapMs)
                assembler.addSpread(texts, voiceId: role, startMs: Int64(line.time).coerced(atLeast: 0), endMs: end,
                                    translation: line.translation)
            } else {
                assembler.addUntapped(tokenize(line.line), voiceId: role, anchorMs: Int64(line.time),
                                      translation: line.translation)
            }
            if assembler.lines.count > before && !usedRoles.contains(where: { $0.isIdentical(to: role) }) {
                usedRoles.append(role)
            }
        }
        return usedRoles.isEmpty ? [Voice()] : usedRoles.map { Voice(id: $0, role: $0) }
    }

    /// Kotlin `CharSequence.lines()`: splits on `\r\n`, `\n` and `\r`, keeping empty lines (and a trailing one).
    static func kotlinLines(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = true
                continue
            } else {
                current.append(scalar)
            }
            previousWasCR = false
        }
        out.append(String(current))
        return out
    }

    /// Kotlin `substringBefore('\n')`.
    static func substringBeforeNewline(_ text: String) -> String {
        guard let index = text.unicodeScalars.firstIndex(of: "\n") else { return text }
        return String(text.unicodeScalars[..<index])
    }

    // MARK: - Small helpers the editor also uses

    /// Media position of a tap: the player's position now, minus the time since the touch event (scaled by speed).
    public static func rawTapPositionMs(positionMs: Int64, nowUptimeMs: Int64, eventUptimeMs: Int64,
                                        speed: Float) -> Int64 {
        positionMs &- KotlinMath.roundToLong(Double((nowUptimeMs &- eventUptimeMs).coerced(atLeast: 0)) * Double(speed))
    }

    /// First tappable (not locked) token index at or after `from`; `tokens.count` if none.
    public static func nextTappable(_ draft: SyncDraft, from: Int) -> Int {
        var i = from.coerced(atLeast: 0)
        while i < draft.tokens.count && draft.lines[draft.tokens[i].line].locked { i += 1 }
        return min(i, draft.tokens.count)
    }

    /// Line of the next word to tap, or the last line once every word is tapped.
    public static func currentLineIndex(_ draft: SyncDraft) -> Int {
        let index = nextTappable(draft, from: draft.cursor)
        return index < draft.tokens.count ? draft.tokens[index].line : draft.lines.count - 1
    }

    /// "Skip this line" is offered only when this line and the next both have an anchor.
    public static func canSkipLine(_ draft: SyncDraft) -> Bool {
        let index = nextTappable(draft, from: draft.cursor)
        if index >= draft.tokens.count { return false }
        let lineIndex = draft.tokens[index].line
        guard let next = nextOpenLine(draft, after: lineIndex) else { return false }
        return draft.lines[lineIndex].anchorMs != nil && draft.lines[next].anchorMs != nil
    }

    /// The preview nudge, clamped to ±400 ms.
    public static func setNudge(_ draft: SyncDraft, nudgeMs: Int) -> SyncDraft {
        var d = draft
        d.nudgeMs = nudgeMs.coerced(in: -maxNudgeMs, maxNudgeMs)
        return d
    }

    /// On save: `offset − nudge × 0.5`, clamped to 0…400 (halved so one odd song can't swing it).
    public static func learnedOffsetMs(currentOffsetMs: Int, nudgeMs: Int) -> Int {
        let rounded = KotlinMath.roundToLong(Double(currentOffsetMs) - Double(nudgeMs) * 0.5)
        return Int(rounded.coerced(in: Int64(Int32.min), Int64(Int32.max))).coerced(in: 0, maxOffsetMs)
    }

    /// Built start of token `index`, or nil while it is untapped.
    public static func builtStartMs(_ draft: SyncDraft, _ index: Int, offsetMs: Int) -> Int64? {
        let token = draft.tokens[index]
        guard let raw = token.rawStartMs else { return nil }
        return raw &- (token.exact ? 0 : offsetShift(offsetMs, token.startSpeed)) &+ Int64(draft.nudgeMs)
    }

    /// Built end of a held word, or nil if it wasn't held.
    public static func builtHeldEndMs(_ draft: SyncDraft, _ index: Int, offsetMs: Int) -> Int64? {
        let token = draft.tokens[index]
        guard let raw = token.rawEndMs else { return nil }
        return raw &- (token.exact ? 0 : offsetShift(offsetMs, token.endSpeed)) &+ Int64(draft.nudgeMs)
    }

    static func offsetShift(_ offsetMs: Int, _ speed: Float) -> Int64 {
        KotlinMath.roundToLong(Double(offsetMs) * Double(speed))
    }

    static func scaled(_ ms: Int64, _ speed: Float) -> Int64 { KotlinMath.roundToLong(Double(ms) * Double(speed)) }

    static func isLocked(_ draft: SyncDraft, _ index: Int) -> Bool { draft.lines[draft.tokens[index].line].locked }

    /// Last stamped, tappable token strictly before `index` (and at or after `floor`).
    static func lastStampedBefore(_ draft: SyncDraft, _ index: Int, floor: Int = 0) -> Int? {
        var i = min(index, draft.tokens.count) - 1
        let lowest = floor.coerced(atLeast: 0)
        while i >= lowest {
            if !isLocked(draft, i) && draft.tokens[i].rawStartMs != nil { return i }
            i -= 1
        }
        return nil
    }

    /// Next line after `lineIndex` that is tapped by the user (not locked, has words).
    static func nextOpenLine(_ draft: SyncDraft, after lineIndex: Int) -> Int? {
        var j = lineIndex + 1
        while j < draft.lines.count {
            let line = draft.lines[j]
            if !line.locked && line.tokenCount > 0 { return j }
            j += 1
        }
        return nil
    }

    static func previousOpenLine(_ draft: SyncDraft, before lineIndex: Int) -> Int? {
        var j = lineIndex - 1
        while j >= 0 {
            let line = draft.lines[j]
            if !line.locked && line.tokenCount > 0 { return j }
            j -= 1
        }
        return nil
    }

    /// `PersistentList<SyncLine>.withSkipped`: sets `skipped` on the given (unlocked) lines.
    static func withSkipped(_ lines: [SyncLine], _ indices: [Int], _ skipped: Bool) -> [SyncLine] {
        var out = lines
        for i in indices where !out[i].locked && out[i].skipped != skipped { out[i].skipped = skipped }
        return out
    }
}
