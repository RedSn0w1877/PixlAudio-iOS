// The tap-sync reducers: each takes a draft and returns a new one (plus where to seek). Ported from the
// "Reducers" section of the Android `LyricsTapSync.kt`.

import Foundation
import PixlFoundation
import PixlModel

extension LyricsTapSync {

    /// "The next word starts now." Stamps the token at the cursor and moves on. Starts stay strictly increasing
    /// (≥ previous + 10 ms) and, when the next line is already timed (Fix a line), stay before it. With `scopeLine`
    /// set, taps outside that line are ignored.
    public static func tap(_ draft: SyncDraft, rawStartMs: Int64, speed: Float, offsetMs: Int,
                           scopeLine: Int? = nil) -> SyncStep {
        let index = nextTappable(draft, from: draft.cursor)
        if index >= draft.tokens.count { return SyncStep(draft: draft) }
        let lineIndex = draft.tokens[index].line
        if let scopeLine, lineIndex != scopeLine { return SyncStep(draft: draft) }

        let shift = offsetShift(offsetMs, speed) &- Int64(draft.nudgeMs) // built = raw − shift
        var built = rawStartMs &- shift
        let previous = lastStampedBefore(draft, index)
        let floor = previous.map { builtStartMs(draft, $0, offsetMs: offsetMs)! &+ minTapGapMs } ?? 0
        if built < floor { built = floor }

        var pastNextLine = false
        let nextLine = nextOpenLine(draft, after: lineIndex)
        let nextLineStart = nextLine.flatMap { builtStartMs(draft, draft.lines[$0].firstToken, offsetMs: offsetMs) }
        if let nextLineStart, built >= nextLineStart &- nextLineGuardMs {
            pastNextLine = true
            built = max(floor, nextLineStart &- nextLineGuardMs &- 1)
        }

        let line = draft.lines[lineIndex]
        let beforeAnchor: Bool
        if index == line.firstToken, let anchor = line.anchorMs {
            beforeAnchor = built < anchor &- earlyTapMs
        } else {
            beforeAnchor = false
        }

        var next = draft
        next.tokens[index].rawStartMs = built &+ shift
        next.tokens[index].startSpeed = speed
        next.tokens[index].rawEndMs = nil
        next.tokens[index].endSpeed = 1
        next.tokens[index].exact = false
        next.cursor = nextTappable(next, from: index + 1)
        return SyncStep(draft: next, pastNextLine: pastNextLine, tapBeforeAnchor: beforeAnchor)
    }

    /// Release after a hold (≥ `holdThresholdMs`): stamps the end of the held word.
    public static func release(_ draft: SyncDraft, tokenIndex: Int, rawEndMs: Int64, speed: Float,
                               offsetMs: Int) -> SyncDraft {
        guard draft.tokens.indices.contains(tokenIndex) else { return draft }
        let token = draft.tokens[tokenIndex]
        if token.rawStartMs == nil || token.exact || isLocked(draft, tokenIndex) { return draft }
        guard let start = builtStartMs(draft, tokenIndex, offsetMs: offsetMs) else { return draft }
        let builtEnd = rawEndMs &- offsetShift(offsetMs, speed) &+ Int64(draft.nudgeMs)
        if builtEnd < start &+ minWordMs { return draft }
        var next = draft
        next.tokens[tokenIndex].rawEndMs = rawEndMs
        next.tokens[tokenIndex].endSpeed = speed
        return next
    }

    /// Removes the last tap and seeks a little before it: 2 s (× speed) before the previous stamped word, or 3 s
    /// before the line anchor / removed tap when there is none. Undoing into a roughly-timed ("skipped") line undoes
    /// the whole skip. With `scopeLine` set (Fix a line), only taps inside that line are undone.
    public static func undo(_ draft: SyncDraft, speed: Float, offsetMs: Int, scopeLine: Int? = nil) -> SyncStep {
        let floor = scopeLine.flatMap { draft.lines.indices.contains($0) ? draft.lines[$0].firstToken : nil } ?? 0
        guard let popped = lastStampedBefore(draft, draft.cursor, floor: floor) else { return SyncStep(draft: draft) }
        let lineIndex = draft.tokens[popped].line
        let line = draft.lines[lineIndex]
        let removedStart = builtStartMs(draft, popped, offsetMs: offsetMs)!
        let undoesSkip = line.skipped && draft.tokens[popped].exact
        // Undoing a rough skip removes the whole roughly-timed run, not just its last word.
        let clearFrom: Int
        if undoesSkip {
            var j = popped
            let lowest = max(line.firstToken, floor)
            while j - 1 >= lowest && draft.tokens[j - 1].exact && draft.tokens[j - 1].rawStartMs != nil { j -= 1 }
            clearFrom = j
        } else {
            clearFrom = popped
        }
        let clearUntil = max(draft.cursor, popped + 1).coerced(atMost: draft.tokens.count)

        var cleared = 0
        var tokens = draft.tokens
        if clearFrom < clearUntil {
            for i in clearFrom..<clearUntil where !isLocked(draft, i) && tokens[i].rawStartMs != nil {
                tokens[i] = tokens[i].cleared()
                cleared += 1
            }
        }
        var result = draft
        result.tokens = tokens
        if undoesSkip { result.lines = withSkipped(draft.lines, [lineIndex], false) }
        result.cursor = nextTappable(result, from: clearFrom)

        let seek: Int64
        if let previous = lastStampedBefore(result, result.cursor) {
            seek = builtStartMs(result, previous, offsetMs: offsetMs)! &- scaled(undoPrerollMs, speed)
        } else {
            seek = (line.anchorMs ?? removedStart) &- scaled(anchorPrerollMs, speed)
        }
        return SyncStep(draft: result, seekToMs: seek.coerced(atLeast: 0), clearedCount: cleared)
    }

    /// Back `ms` (default 5 s) from `positionMs`: forgets every tap whose built start is at or after the new position
    /// and moves the cursor to the first forgotten word. Also used for backward seeks on the editor's seek bar. With
    /// `scopeLine` set, only that line is touched.
    public static func rewind(_ draft: SyncDraft, positionMs: Int64, offsetMs: Int, ms: Int64 = rewindMs,
                              scopeLine: Int? = nil) -> SyncStep {
        let newPosition = (positionMs &- ms).coerced(atLeast: 0)
        let range: Range<Int>
        if let scopeLine, draft.lines.indices.contains(scopeLine) {
            let line = draft.lines[scopeLine]
            range = line.firstToken..<max(line.firstToken, line.endToken)
        } else {
            range = draft.tokens.indices
        }
        var first = -1
        var cleared = 0
        var tokens = draft.tokens
        for i in range {
            if isLocked(draft, i) { continue }
            guard let start = builtStartMs(draft, i, offsetMs: offsetMs) else { continue }
            if start >= newPosition {
                tokens[i] = tokens[i].cleared()
                cleared += 1
                if first < 0 { first = i }
            }
        }
        if cleared == 0 { return SyncStep(draft: draft, seekToMs: newPosition) }
        var base = draft
        base.tokens = tokens
        base.cursor = nextTappable(base, from: min(draft.cursor, first))
        return SyncStep(draft: base, seekToMs: newPosition, clearedCount: cleared)
    }

    /// Tap on a line at or before the current one: forget line `lineIndex` onwards and start tapping it again, 2 s
    /// (× speed) before its first word / anchor / the previous line's end.
    public static func jumpToLine(_ draft: SyncDraft, lineIndex: Int, speed: Float, offsetMs: Int) -> SyncStep {
        guard draft.lines.indices.contains(lineIndex) else { return SyncStep(draft: draft) }
        let line = draft.lines[lineIndex]
        if line.locked || line.tokenCount == 0 || lineIndex > currentLineIndex(draft) { return SyncStep(draft: draft) }
        let target = lineSeekBase(draft, lineIndex, offsetMs: offsetMs) &- scaled(undoPrerollMs, speed)
        return clearLines(draft, lineIndex...(draft.lines.count - 1), seekToMs: target.coerced(atLeast: 0))
    }

    /// Fix a line from Preview: forget only line `lineIndex`; later lines keep their timing.
    public static func fixLine(_ draft: SyncDraft, lineIndex: Int, speed: Float, offsetMs: Int) -> SyncStep {
        guard draft.lines.indices.contains(lineIndex) else { return SyncStep(draft: draft) }
        let line = draft.lines[lineIndex]
        if line.locked || line.tokenCount == 0 { return SyncStep(draft: draft) }
        let target = lineSeekBase(draft, lineIndex, offsetMs: offsetMs) &- scaled(fixLinePrerollMs, speed)
        return clearLines(draft, lineIndex...lineIndex, seekToMs: target.coerced(atLeast: 0))
    }

    private static func clearLines(_ draft: SyncDraft, _ lineRange: ClosedRange<Int>, seekToMs: Int64) -> SyncStep {
        let firstToken = draft.lines[lineRange.lowerBound].firstToken
        let lastToken = draft.lines[lineRange.upperBound].endToken
        var cleared = 0
        var tokens = draft.tokens
        if firstToken < lastToken {
            for i in firstToken..<lastToken where !isLocked(draft, i) && tokens[i].rawStartMs != nil {
                tokens[i] = tokens[i].cleared()
                cleared += 1
            }
        }
        var base = draft
        base.tokens = tokens
        base.lines = withSkipped(draft.lines, Array(lineRange), false)
        base.cursor = nextTappable(base, from: firstToken)
        return SyncStep(draft: base, seekToMs: seekToMs, clearedCount: cleared)
    }

    /// First word's start, else the line anchor, else where the previous line ends, else 0.
    private static func lineSeekBase(_ draft: SyncDraft, _ lineIndex: Int, offsetMs: Int) -> Int64 {
        let line = draft.lines[lineIndex]
        if let start = builtStartMs(draft, line.firstToken, offsetMs: offsetMs) { return start }
        if let anchor = line.anchorMs { return anchor }
        guard let previous = previousOpenLine(draft, before: lineIndex),
              let timing = resolveTiming(draft, offsetMs: offsetMs) else { return 0 }
        let prevLine = draft.lines[previous]
        return (prevLine.firstToken..<prevLine.endToken).map { timing.endsMs[$0] }.max()!
    }

    /// "Skip this line (time it roughly)": spreads the line's remaining words by character count between the last
    /// tap in the line (or its anchor) and the next line's anchor.
    public static func skipLine(_ draft: SyncDraft, offsetMs: Int) -> SyncStep {
        if !canSkipLine(draft) { return SyncStep(draft: draft) }
        let index = nextTappable(draft, from: draft.cursor)
        let lineIndex = draft.tokens[index].line
        let line = draft.lines[lineIndex]
        let nextAnchor = draft.lines[nextOpenLine(draft, after: lineIndex)!].anchorMs!
        let lastTapped = lastStampedBefore(draft, index, floor: line.firstToken)
        let from = lastTapped.map { builtStartMs(draft, $0, offsetMs: offsetMs)! } ?? line.anchorMs!
        let to = max(nextAnchor, from)

        let indices = Array(index..<max(index, line.endToken))
        let leftWeight = lastTapped.map { weight(draft.tokens[$0].text) } ?? 0
        let total = indices.reduce(leftWeight) { $0 &+ weight(draft.tokens[$1].text) }
        var accumulated = leftWeight
        var tokens = draft.tokens
        for i in indices {
            let start = from &+ (to &- from) &* accumulated / total
            accumulated &+= weight(tokens[i].text)
            tokens[i].rawStartMs = start &- Int64(draft.nudgeMs)
            tokens[i].startSpeed = 1
            tokens[i].rawEndMs = nil
            tokens[i].endSpeed = 1
            tokens[i].exact = true
        }
        var base = draft
        base.tokens = tokens
        base.lines = withSkipped(draft.lines, [lineIndex], true)
        base.cursor = nextTappable(base, from: line.endToken)
        return SyncStep(draft: base)
    }

    /// "Time the rest roughly": spreads every untapped word after the cursor evenly between the last word's end and
    /// the song's end − 500 ms, at most 600 ms per word.
    public static func fillRest(_ draft: SyncDraft, offsetMs: Int) -> SyncStep {
        let start = nextTappable(draft, from: draft.cursor)
        let remaining = (start..<max(start, draft.tokens.count)).filter {
            !isLocked(draft, $0) && draft.tokens[$0].rawStartMs == nil
        }
        if remaining.isEmpty {
            var done = draft
            done.cursor = draft.tokens.count
            return SyncStep(draft: done)
        }

        let from: Int64
        if let lastStamped = lastStampedBefore(draft, start) {
            from = resolveTiming(draft, offsetMs: offsetMs)?.endsMs[lastStamped]
                ?? (builtStartMs(draft, lastStamped, offsetMs: offsetMs)! &+ defaultGapMs)
        } else {
            from = draft.lines[draft.tokens[start].line].anchorMs ?? 0
        }
        let limit = hasKnownDuration(draft)
            ? draft.durationMs &- tailMarginMs
            : from &+ roughWordMaxMs &* Int64(remaining.count)
        let perWord = ((limit &- from) / Int64(remaining.count)).coerced(in: 1, roughWordMaxMs)
        var tokens = draft.tokens
        for (k, i) in remaining.enumerated() {
            tokens[i].rawStartMs = from &+ perWord &* Int64(k) &- Int64(draft.nudgeMs)
            tokens[i].startSpeed = 1
            tokens[i].rawEndMs = nil
            tokens[i].endSpeed = 1
            tokens[i].exact = true
        }
        var lineIndices: [Int] = []
        for i in remaining where !lineIndices.contains(draft.tokens[i].line) { lineIndices.append(draft.tokens[i].line) }
        var result = draft
        result.tokens = tokens
        result.lines = withSkipped(draft.lines, lineIndices, true)
        result.cursor = draft.tokens.count
        return SyncStep(draft: result)
    }

    /// "Start over" / "Tap Start to redo it": forget every tap (locked lines are kept).
    public static func clearAll(_ draft: SyncDraft) -> SyncDraft {
        var base = draft
        for i in base.tokens.indices where !isLocked(draft, i) && base.tokens[i].rawStartMs != nil {
            base.tokens[i] = base.tokens[i].cleared()
        }
        base.lines = withSkipped(draft.lines, Array(draft.lines.indices), false)
        base.cursor = nextTappable(base, from: 0)
        return base
    }
}
