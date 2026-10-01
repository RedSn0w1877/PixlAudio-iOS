// The bookkeeping of the iOS streaming cache: which byte ranges of a remote audio file are already on disk. The
// resource loader serves covered ranges from the sparse cache file and fetches only the gaps (googlevideo range
// requests); a file whose ranges cover its whole length plays from disk. Swift-only (Android used ExoPlayer's
// SimpleCache), so the tests here are its specification.

import Foundation

/// A set of half-open byte ranges, kept sorted, non-overlapping and with touching ranges merged.
public struct ByteRangeSet: Sendable, Hashable, Codable {
    /// One `[start, end)` span (Codable as `[start, end]`).
    public struct Span: Sendable, Hashable, Codable {
        public var start: Int64
        public var end: Int64

        public init(_ start: Int64, _ end: Int64) {
            self.start = start
            self.end = end
        }

        public init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Int64.self)
            end = try container.decode(Int64.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(start)
            try container.encode(end)
        }

        public var length: Int64 { end - start }
        public var range: Range<Int64> { start..<end }
    }

    public private(set) var spans: [Span]

    public init() { spans = [] }

    public init(_ ranges: [Range<Int64>]) {
        spans = []
        for range in ranges { insert(range) }
    }

    public init(from decoder: any Decoder) throws {
        let decoded = try decoder.singleValueContainer().decode([Span].self)
        spans = []
        for span in decoded where span.end > span.start && span.start >= 0 { insert(span.range) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(spans)
    }

    public var isEmpty: Bool { spans.isEmpty }

    /// Total bytes covered.
    public var coveredBytes: Int64 { spans.reduce(0) { $0 + $1.length } }

    /// Adds `range`, merging it with every span it overlaps or touches. Empty ranges are ignored.
    public mutating func insert(_ range: Range<Int64>) {
        guard range.lowerBound >= 0, !range.isEmpty else { return }
        var start = range.lowerBound
        var end = range.upperBound
        var merged: [Span] = []
        merged.reserveCapacity(spans.count + 1)
        var inserted = false
        for span in spans {
            if span.end < start {
                merged.append(span)
            } else if span.start > end {
                if !inserted {
                    merged.append(Span(start, end))
                    inserted = true
                }
                merged.append(span)
            } else {
                start = min(start, span.start)
                end = max(end, span.end)
            }
        }
        if !inserted { merged.append(Span(start, end)) }
        spans = merged
    }

    /// Whether every byte of `range` is covered (an empty range is).
    public func contains(_ range: Range<Int64>) -> Bool {
        if range.isEmpty { return true }
        return spans.contains { $0.start <= range.lowerBound && $0.end >= range.upperBound }
    }

    /// How many bytes from `offset` on are covered contiguously (capped at `limit` when given).
    public func contiguousLength(from offset: Int64, limit: Int64? = nil) -> Int64 {
        guard let span = spans.first(where: { $0.start <= offset && $0.end > offset }) else { return 0 }
        let length = span.end - offset
        return limit.map { min($0, length) } ?? length
    }

    /// The uncovered parts of `range`, in order.
    public func gaps(in range: Range<Int64>) -> [Range<Int64>] {
        guard !range.isEmpty else { return [] }
        var out: [Range<Int64>] = []
        var cursor = range.lowerBound
        for span in spans where span.end > range.lowerBound && span.start < range.upperBound {
            if span.start > cursor { out.append(cursor..<min(span.start, range.upperBound)) }
            cursor = max(cursor, span.end)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound { out.append(cursor..<range.upperBound) }
        return out
    }

    /// The first uncovered byte range starting at or after `offset` within `0..<length`, at most `maxLength` long.
    public func nextGap(from offset: Int64, length: Int64, maxLength: Int64) -> Range<Int64>? {
        guard offset < length, maxLength > 0 else { return nil }
        guard let gap = gaps(in: max(offset, 0)..<length).first else { return nil }
        return gap.lowerBound..<min(gap.upperBound, gap.lowerBound + maxLength)
    }

    /// Whether the whole file `0..<length` is covered (a zero-length file never is: its size is unknown).
    public func isComplete(length: Int64) -> Bool {
        length > 0 && contains(0..<length)
    }
}

/// HTTP `Content-Range` parsing for the streaming cache (`bytes 0-1/12345`).
public enum ContentRange {
    /// The parts of a `Content-Range: bytes <start>-<end>/<total>` header (`total` nil for `*`).
    public struct Value: Sendable, Hashable {
        public var start: Int64
        public var endInclusive: Int64
        public var total: Int64?
    }

    public static func parse(_ header: String?) -> Value? {
        guard let header else { return nil }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = text.dropFirst("bytes ".count)
        let halves = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)), start >= 0, end >= start else { return nil }
        let totalText = halves[1].trimmingCharacters(in: .whitespaces)
        let total: Int64?
        if totalText == "*" {
            total = nil
        } else {
            guard let value = Int64(totalText), value > end else { return nil }
            total = value
        }
        return Value(start: start, endInclusive: end, total: total)
    }

    /// The `Range` request header for `range` (`bytes=a-b`, inclusive end).
    public static func requestHeader(_ range: Range<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
    }
}
