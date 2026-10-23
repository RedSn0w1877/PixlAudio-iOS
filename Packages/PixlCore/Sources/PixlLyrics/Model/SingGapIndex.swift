// Where the singer is silent: the gaps between the sung words of a song, for the Sing button's switch to the
// instrumental (it crossfades at a word gap, so the fade never lands on a sung word). Pure: built once from a song's
// `PreparedLyrics` when the switch is about to happen, queried by `SingSwitchPlanner`.

import Foundation

/// The stretches of a song that are sung, merged, and the quiet between them.
///
/// Every syllable of every line counts, background vocals and both voices of a duet included (they overlap, so the
/// spans are merged), padded a little on both sides: a word is heard slightly before and after its timing. Lyrics
/// without word timing have no gaps to find (`hasWordTiming` is false and `gaps` is empty); a line of lyrics that is
/// timed by line only, inside lyrics that are word-timed elsewhere, counts as sung for its whole length, so it never
/// shows up as a gap.
public struct SingGapIndex: Sendable, Equatable {
    /// The start of a gap that has nothing before it, and the end of one that has nothing after it. Far from the
    /// `Int64` limits, so sums and differences with song times cannot overflow.
    public static let openStartMs: Int64 = Int64.min / 4
    public static let openEndMs: Int64 = Int64.max / 4

    /// One merged stretch of singing, `[startMs, endMs]` in lyrics time, padding included.
    public struct Span: Sendable, Equatable {
        public let startMs: Int64
        public let endMs: Int64

        public init(startMs: Int64, endMs: Int64) {
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    /// At least one syllable has a timing, so the gaps mean something.
    public let hasWordTiming: Bool
    /// The sung stretches, sorted, with no overlap or touching between neighbours.
    public let spans: [Span]

    /// `padBeforeMs` widens every sung stretch to the left, `padAfterMs` to the right.
    public init(_ lyrics: PreparedLyrics, padBeforeMs: Int64 = 80, padAfterMs: Int64 = 120) {
        let wordTimed = lyrics.lines.contains { $0.hasWordTiming }
        guard wordTimed else {
            hasWordTiming = false
            spans = []
            return
        }
        var raw: [Span] = []
        for line in lyrics.lines {
            if let syllables = line.syllables, !syllables.isEmpty {
                for syllable in syllables {
                    raw.append(Span(startMs: syllable.startMs - padBeforeMs,
                                    endMs: Swift.max(syllable.endMs, syllable.startMs) + padAfterMs))
                }
            } else {
                // A line without word timing next to lines that have it: the whole line is sung.
                raw.append(Span(startMs: line.startMs - padBeforeMs, endMs: Swift.max(line.endMs, line.startMs) + padAfterMs))
            }
        }
        hasWordTiming = true
        spans = Self.merged(raw)
    }

    /// The quiet stretches that overlap `[tMs, uMs]`, in order, with their real bounds (a gap that runs past `uMs`
    /// is returned whole; the one before the first word starts at `openStartMs` and the one after the last word ends
    /// at `openEndMs`). Empty when the lyrics have no word timing.
    public func gaps(from tMs: Int64, to uMs: Int64) -> [(start: Int64, end: Int64)] {
        guard hasWordTiming, !spans.isEmpty, uMs >= tMs else { return [] }
        // The first gap that ends after `tMs` is the one in front of the first span starting after `tMs`.
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].startMs > tMs { high = mid } else { low = mid + 1 }
        }
        var found: [(start: Int64, end: Int64)] = []
        var index = low
        while index <= spans.count {
            let start = index == 0 ? Self.openStartMs : spans[index - 1].endMs
            if start > uMs { break }
            let end = index == spans.count ? Self.openEndMs : spans[index].startMs
            found.append((start: start, end: end))
            index += 1
        }
        return found
    }

    /// Sorted by start, overlapping and touching spans joined.
    private static func merged(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.endMs < $1.endMs }
        var out: [Span] = []
        out.reserveCapacity(sorted.count)
        for span in sorted {
            if let last = out.last, span.startMs <= last.endMs {
                if span.endMs > last.endMs { out[out.count - 1] = Span(startMs: last.startMs, endMs: span.endMs) }
            } else {
                out.append(span)
            }
        }
        return out
    }
}
