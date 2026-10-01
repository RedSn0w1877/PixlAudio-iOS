// Timing resolution and the finished document, ported from the "Timing resolution and the finished document"
// section of the Android `LyricsTapSync.kt`.

import Foundation
import PixlFoundation
import PixlModel

extension LyricsTapSync {

    static func hasKnownDuration(_ draft: SyncDraft) -> Bool {
        (minKnownDurationMs...maxDocDurationMs).contains(draft.durationMs)
    }

    static func durationCap(_ draft: SyncDraft) -> Int64 {
        hasKnownDuration(draft) ? draft.durationMs : maxDocDurationMs
    }

    /// Built start and end for every token. Untapped words are filled in roughly: a line anchor when it fits, else by
    /// character count between the neighbouring taps, else ≤ 600 ms apart. Returns nil while no tappable word has
    /// been tapped.
    public static func resolveTiming(_ draft: SyncDraft, offsetMs: Int) -> SyncTiming? {
        let tokens = draft.tokens
        let n = tokens.count
        if n == 0 { return nil }
        let cap = durationCap(draft)
        let startCeiling = cap - 2
        let endCeiling = cap - 1

        var starts = [Int64](repeating: 0, count: n)
        var known = [Bool](repeating: false, count: n)
        var rough = Set<Int>()
        var anyOpenStamped = false
        var anyOpen = false
        for i in 0..<n {
            let locked = isLocked(draft, i)
            if !locked { anyOpen = true }
            guard let start = builtStartMs(draft, i, offsetMs: offsetMs) else { continue }
            starts[i] = start.coerced(in: 0, startCeiling)
            known[i] = true
            if !locked { anyOpenStamped = true }
        }
        if anyOpen && !anyOpenStamped { return nil }
        for (index, line) in draft.lines.enumerated() where line.skipped { rough.insert(index) }
        keepLineOrder(draft, &starts, known)

        // Positions that take part in filling: everything except already-timed locked words.
        let order = (0..<n).filter { !(known[$0] && isLocked(draft, $0)) }
        var nextKnownPosition = [Int](repeating: -1, count: order.count)
        var upcoming = -1
        for p in order.indices.reversed() {
            nextKnownPosition[p] = upcoming
            if known[order[p]] { upcoming = p }
        }

        // Anchors of untapped lines, where they fit between the surrounding taps.
        var previousKnown: Int64?
        for p in order.indices {
            let i = order[p]
            if known[i] {
                previousKnown = starts[i]
                continue
            }
            let lineIndex = tokens[i].line
            let line = draft.lines[lineIndex]
            guard let anchor = line.anchorMs else { continue }
            if i != line.firstToken { continue }
            let a = anchor.coerced(in: 0, startCeiling)
            let nextPosition = nextKnownPosition[p]
            let next: Int64? = nextPosition >= 0 ? starts[order[nextPosition]] : nil
            if (previousKnown.map { a >= $0 } ?? true) && (next.map { a <= $0 } ?? true) {
                starts[i] = a
                known[i] = true
                rough.insert(lineIndex)
                previousKnown = a
            }
        }

        // Fill every remaining run of untapped words.
        var p = 0
        while p < order.count {
            if known[order[p]] {
                p += 1
                continue
            }
            var q = p
            while q + 1 < order.count && !known[order[q + 1]] { q += 1 }
            let left = p > 0 ? order[p - 1] : -1
            let right = q + 1 < order.count ? order[q + 1] : -1
            let count = Int64(q - p + 1)
            if left >= 0 && right >= 0 {
                let from = starts[left]
                let to = max(starts[right], from)
                let leftWeight = weight(tokens[left].text)
                var total = leftWeight
                for k in p...q { total &+= weight(tokens[order[k]].text) }
                var accumulated = leftWeight
                for k in p...q {
                    starts[order[k]] = from &+ (to &- from) &* accumulated / total
                    accumulated &+= weight(tokens[order[k]].text)
                }
            } else if left >= 0 {
                let from = starts[left]
                let perWord = ((cap &- tailMarginMs &- from) / (count + 1)).coerced(in: 1, roughWordMaxMs)
                for k in 0..<Int(count) { starts[order[p + k]] = from &+ perWord &* Int64(k + 1) }
            } else if right >= 0 {
                let to = starts[right]
                let perWord = (to / (count + 1)).coerced(in: 1, roughWordMaxMs)
                for k in 0..<Int(count) {
                    starts[order[p + k]] = (to &- perWord &* (count - Int64(k))).coerced(atLeast: 0)
                }
            } else {
                for k in 0..<Int(count) { starts[order[p + k]] = 0 }
            }
            for k in p...q {
                known[order[k]] = true
                rough.insert(tokens[order[k]].line)
            }
            p = q + 1
        }
        for i in 0..<n { starts[i] = starts[i].coerced(in: 0, startCeiling) }
        keepLineOrder(draft, &starts, known)

        // Ends.
        var ends = [Int64](repeating: 0, count: n)
        var nextLineStart = [Int64?](repeating: nil, count: draft.lines.count)
        var following: Int64?
        for lineIndex in draft.lines.indices.reversed() {
            let line = draft.lines[lineIndex]
            nextLineStart[lineIndex] = following
            if !line.locked && line.tokenCount > 0 { following = starts[line.firstToken] }
        }
        for (lineIndex, line) in draft.lines.enumerated() {
            if line.tokenCount <= 0 { continue }
            let range = line.firstToken..<line.endToken
            let loadedIntact = range.allSatisfy { tokens[$0].exact && tokens[$0].rawEndMs != nil }
            if loadedIntact {
                for i in range {
                    let end = builtHeldEndMs(draft, i, offsetMs: offsetMs)!
                    ends[i] = end.coerced(atMost: endCeiling).coerced(atLeast: starts[i] &+ 1)
                }
                continue
            }
            let derived = deriveEnds(
                starts: range.map { starts[$0] },
                heldEnds: range.map { builtHeldEndMs(draft, $0, offsetMs: offsetMs) },
                nextLineStartMs: line.locked ? nil : nextLineStart[lineIndex],
                endCeilingMs: endCeiling
            )
            for (k, i) in range.enumerated() { ends[i] = derived[k] }
        }
        return SyncTiming(startsMs: starts, endsMs: ends, roughLines: rough)
    }

    /// Word starts never go backwards inside a line.
    private static func keepLineOrder(_ draft: SyncDraft, _ starts: inout [Int64], _ known: [Bool]) {
        for line in draft.lines where line.tokenCount > 0 {
            var previous = Int64.min
            for i in line.firstToken..<line.endToken {
                if !known[i] { continue }
                if starts[i] < previous { starts[i] = previous }
                previous = starts[i]
            }
        }
    }

    /// Word ends for one line (spec §3.4), given non-decreasing `starts` each ≤ `endCeilingMs` − 1.
    /// - held word → its held end;
    /// - otherwise the next word's start when it follows within 4 s (a continuous sweep), else
    ///   `start + clamp(median gap, 250, 1200)`;
    /// - last word → `start + clamp(2 × median gap, 400, 2000)`.
    /// Then `≤ nextLineStart − 1`, `≥ start + 40`, `≤ endCeiling`, and always `> start`.
    public static func deriveEnds(starts: [Int64], heldEnds: [Int64?], nextLineStartMs: Int64?,
                                  endCeilingMs: Int64) -> [Int64] {
        let n = starts.count
        if n == 0 { return [] }
        let median = medianGap(starts)
        return (0..<n).map { i in
            let start = starts[i]
            var end: Int64
            if i < heldEnds.count, let held = heldEnds[i] {
                end = held
            } else if i < n - 1 {
                let gap = starts[i + 1] &- start
                end = gap <= sustainGapMs ? starts[i + 1] : start &+ median.coerced(in: 250, 1_200)
            } else {
                end = start &+ (2 &* median).coerced(in: 400, 2_000)
            }
            if let nextLineStartMs, nextLineStartMs > starts[0] { end = min(end, nextLineStartMs &- 1) }
            end = max(end, start &+ minWordMs)
            end = min(end, endCeilingMs)
            return max(end, start &+ 1)
        }
    }

    private static func medianGap(_ starts: [Int64]) -> Int64 {
        if starts.count < 2 { return defaultGapMs }
        let gaps = (0..<(starts.count - 1)).map { starts[$0 + 1] &- starts[$0] }.sorted()
        let middle = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[middle] : (gaps[middle - 1] &+ gaps[middle]) / 2
    }

    /// The finished lyrics, `metadata.source = "user"`, always passing `LyricsDocCodec.isValid`.
    public static func toLyricsDoc(_ draft: SyncDraft, offsetMs: Int) -> Result<LyricsDoc, LyricsTapSyncError> {
        buildResult(draft, offsetMs: offsetMs).map(\.doc)
    }

    /// The finished lyrics plus which of its lines were timed roughly.
    public static func buildResult(_ draft: SyncDraft, offsetMs: Int) -> Result<SyncResult, LyricsTapSyncError> {
        guard let timing = resolveTiming(draft, offsetMs: offsetMs) else { return .failure(.noTaps) }
        let (voices, voiceFor) = sanitizeVoices(draft)

        var built: [(line: TimedLine, rough: Bool)] = []
        for (lineIndex, line) in draft.lines.enumerated() where line.tokenCount > 0 {
            let syllables = (line.firstToken..<line.endToken).map { i in
                TimedSyllable(startMs: timing.startsMs[i], durationMs: timing.endsMs[i] &- timing.startsMs[i],
                              text: draft.tokens[i].text)
            }
            built.append((
                line: TimedLine(
                    startMs: syllables[0].startMs,
                    endMs: syllables.map { $0.startMs &+ $0.durationMs }.max()!,
                    text: syllables.map(\.text).joined(),
                    voiceId: voiceFor(line.voiceId),
                    syllables: syllables
                ),
                rough: timing.roughLines.contains(lineIndex)
            ))
        }
        // `sortedBy { it.line.startMs }` is stable: text order breaks ties.
        built = built.enumerated()
            .sorted { $0.element.line.startMs != $1.element.line.startMs
                ? $0.element.line.startMs < $1.element.line.startMs : $0.offset < $1.offset }
            .map(\.element)
        if built.isEmpty { return .failure(.noWords) }

        let doc = LyricsDoc(
            metadata: LyricsMetadata(
                title: draft.title,
                artist: draft.artist,
                album: draft.album,
                durationMs: hasKnownDuration(draft) ? draft.durationMs : nil,
                source: sourceUser
            ),
            voices: voices,
            lines: built.map(\.line)
        )
        if !LyricsDocCodec.isValid(doc) {
            var single = doc
            let badIndex = doc.lines.firstIndex { line in
                single.lines = [line]
                return !LyricsDocCodec.isValid(single)
            } ?? -1
            let badLine = badIndex >= 0 ? String(describing: doc.lines[badIndex]) : "null"
            return .failure(.invalidDocument(
                "Tap-sync produced an invalid lyrics document (first invalid line \(badIndex): \(badLine))"))
        }
        let roughIndices = Set(built.indices.filter { built[$0].rough })
        return .success(SyncResult(doc: doc, roughLineIndices: roughIndices))
    }

    private static func sanitizeVoices(_ draft: SyncDraft) -> ([Voice], (String) -> String) {
        var voices: [Voice] = []
        func contains(_ id: String) -> Bool { voices.contains { $0.id.isIdentical(to: id) } }
        for voice in draft.voices {
            if voices.count >= maxVoices { break }
            if voice.id.isKotlinBlank || contains(voice.id) { continue }
            if isVoiceRole(voice.role) {
                voices.append(voice)
            } else {
                var lead = voice
                lead.role = VoiceRole.lead
                voices.append(lead)
            }
        }
        for line in draft.lines {
            if voices.count >= maxVoices { break }
            if line.tokenCount > 0 && !line.voiceId.isKotlinBlank && !contains(line.voiceId) {
                let role = isVoiceRole(line.voiceId) ? line.voiceId : VoiceRole.lead
                voices.append(Voice(id: line.voiceId, role: role))
            }
        }
        if voices.isEmpty { voices.append(Voice()) }
        let fallback = (voices.first { $0.role.isIdentical(to: VoiceRole.lead) } ?? voices[0]).id
        let final = voices
        return (final, { id in final.contains { $0.id.isIdentical(to: id) } ? id : fallback })
    }

    /// Structural sanity check, used when a stored draft is read back.
    public static func isConsistent(_ draft: SyncDraft) -> Bool {
        if draft.lines.isEmpty || draft.tokens.isEmpty { return false }
        if !(0...draft.tokens.count).contains(draft.cursor) { return false }
        var expectedFirst = 0
        for (lineIndex, line) in draft.lines.enumerated() {
            if line.firstToken != expectedFirst || line.tokenCount <= 0 { return false }
            if line.endToken > draft.tokens.count { return false }
            var text = ""
            for i in line.firstToken..<line.endToken {
                let token = draft.tokens[i]
                if token.line != lineIndex || token.text.isEmpty { return false }
                if token.startSpeed.isNaN || token.startSpeed <= 0 || token.endSpeed.isNaN || token.endSpeed <= 0 {
                    return false
                }
                if line.locked && token.rawStartMs == nil { return false }
                text += token.text
            }
            if !text.isIdentical(to: line.text) { return false }
            expectedFirst = line.endToken
        }
        return expectedFirst == draft.tokens.count
    }
}
