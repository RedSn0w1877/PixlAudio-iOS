// Port of `data/youtube/TrackMatcher.kt`: matches a Spotify track to a YouTube Music video. The real risk is not
// finding nothing but finding the *wrong* recording, so duration weighs heavily and "live"/"remix"/… cost points
// unless the Spotify title says so too. All arithmetic is Kotlin `Float` (32-bit), as on Android.

import Foundation

/// The metadata a match is made on (`SpotifySongEntity`'s title/artist/album/duration).
public struct MatchableTrack: Sendable, Hashable {
    public var title: String
    /// Spotify's comma-joined artist list ("Primary, Featured").
    public var artist: String
    public var album: String
    public var durationMs: Int64

    public init(title: String, artist: String, album: String, durationMs: Int64) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
    }
}

/// A chosen video.
public struct TrackMatch: Sendable, Hashable {
    public var videoId: String
    public var score: Float
    public var candidateTitle: String

    public init(videoId: String, score: Float, candidateTitle: String) {
        self.videoId = videoId
        self.score = score
        self.candidateTitle = candidateTitle
    }
}

/// The YouTube Music searches a matcher runs (`InnerTubeClient` conforms).
public protocol YouTubeMusicSearching: Sendable {
    func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult]
    func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult]
}

/// Thrown when no acceptable match was found because every search failed (the song stays PENDING).
public struct MusicSearchUnavailableError: Error, Sendable, Hashable {
    public let message = "Music search temporarily unavailable"
    public let underlying: String
}

/// `TrackMatcher`.
public struct TrackMatcher: Sendable {
    public static let candidatesPerQuery = 8
    public static let minAcceptScore: Float = 0.55
    public static let earlyAcceptScore: Float = 0.88

    static let titleWeight: Float = 0.40
    static let artistWeight: Float = 0.25
    static let durationWeight: Float = 0.30
    static let albumBonus: Float = 0.05
    static let variantPenalty: Float = 0.25
    static let exactDurationToleranceSeconds = 3
    static let looseDurationToleranceSeconds = 8

    static let variantPenaltyWords = ["live", "cover", "remix", "sped up", "slowed", "nightcore",
                                      "karaoke", "instrumental", "8d audio", "reverb"]

    public let search: any YouTubeMusicSearching

    public init(search: any YouTubeMusicSearching) {
        self.search = search
    }

    // MARK: Matching

    /// `findMatch`: song searches per query (stopping early at 0.88), then the video shelf of the first query when
    /// nothing scored that high. Throws when nothing acceptable was found and a search failed.
    public func findMatch(_ song: MatchableTrack) async throws -> TrackMatch? {
        let queries = Self.buildQueries(song)
        var best: TrackMatch?
        var lastFailure: (any Error)?

        func consider(_ query: String, videos: Bool) async throws {
            let candidates: [YouTubeSearchResult]
            do {
                candidates = videos
                    ? try await search.searchVideos(query, limit: Self.candidatesPerQuery)
                    : try await search.searchSongs(query, limit: Self.candidatesPerQuery)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error
                return
            }
            for candidate in candidates {
                let score = Self.score(song, candidate)
                if best == nil || score > best!.score {
                    best = TrackMatch(videoId: candidate.videoId, score: score, candidateTitle: candidate.title)
                }
            }
        }

        for query in queries {
            try await consider(query, videos: false)
            if let current = best, current.score >= Self.earlyAcceptScore { return current }
        }
        if best == nil || best!.score < Self.earlyAcceptScore {
            try await consider(queries[0], videos: true)
        }
        if best == nil || best!.score < Self.minAcceptScore, let lastFailure {
            throw MusicSearchUnavailableError(underlying: String(describing: lastFailure))
        }
        guard let result = best, result.score >= Self.minAcceptScore else { return nil }
        return result
    }

    /// `buildQueries`: "title primaryArtist", "title primaryArtist album" (real albums only), "title" — distinct.
    public static func buildQueries(_ song: MatchableTrack) -> [String] {
        let primaryArtist = NetText.trim(NetText.substringBefore(song.artist, ","))
        var queries = ["\(song.title) \(primaryArtist)"]
        if !NetText.isBlank(song.album) && !NetText.equalsIgnoreCase(song.album, "Unknown Album") {
            queries.append("\(song.title) \(primaryArtist) \(song.album)")
        }
        queries.append(song.title)
        var seen = Set<String>()
        return queries.filter { seen.insert($0).inserted }
    }

    // MARK: Scoring

    /// `score(song, candidate)` in 0…1.
    public static func score(_ song: MatchableTrack, _ candidate: YouTubeSearchResult) -> Float {
        var score: Float = 0

        let songTitle = normalize(song.title)
        let normalizedArtist = normalize(NetText.substringBefore(song.artist, ","))
        let videoTitleParts = splitVideoTitle(candidate.title)
        let hasExactVideoArtist = candidate.isMusicVideo && videoTitleParts.count == 2 && NetText.same(normalize(videoTitleParts[0]), normalizedArtist)
        let candidateTitle = hasExactVideoArtist ? normalize(videoTitleParts[1]) : normalize(candidate.title)
        let titleSimilarity = similarity(songTitle, candidateTitle)
        score += titleSimilarity * titleWeight

        let songArtist = normalize(NetText.substringBefore(song.artist, ","))
        var candidateArtist = normalize(candidate.artist)
        candidateArtist = NetText.removeSuffix(candidateArtist, " topic")
        candidateArtist = NetText.removeSuffix(candidateArtist, "vevo")
        candidateArtist = NetText.trim(candidateArtist)
        let artistScore = max(artistSimilarity(songArtist, candidateArtist), hasExactVideoArtist ? Float(0.9) : 0)
        if titleSimilarity < 0.55 || artistScore < 0.65 { return 0 }
        score += artistScore * artistWeight

        // Duration: the most reliable sign that it is the *same* recording.
        let expectedSeconds = Int(Int32(truncatingIfNeeded: song.durationMs / 1000))
        if let actualSeconds = candidate.durationSeconds, expectedSeconds > 0 {
            let difference = abs(actualSeconds - expectedSeconds)
            if difference <= exactDurationToleranceSeconds {
                score += durationWeight
            } else if difference <= looseDurationToleranceSeconds {
                score += durationWeight * 0.5
            } else {
                score += -durationWeight
            }
        }

        if let album = candidate.album, !NetText.isBlank(album), similarity(normalize(song.album), normalize(album)) > 0.85 {
            score += albumBonus
        }

        // Unwanted variants, unless the Spotify track announces them.
        for word in variantPenaltyWords {
            if containsPhrase(candidateTitle, word) && !containsPhrase(songTitle, word) { score -= variantPenalty }
        }
        return min(max(score, 0), 1)
    }

    /// Artists compare by tokens: YouTube Music often shows only the primary artist while Spotify lists everyone.
    static func artistSimilarity(_ source: String, _ candidate: String) -> Float {
        if NetText.isBlank(source) || NetText.isBlank(candidate) { return 0 }
        if NetText.same(source, candidate) { return 1 }
        if NetText.containsExact(" \(candidate) ", " \(source) ") { return 0.9 }
        let sourceTokens = Set(source.split(separator: " ", omittingEmptySubsequences: false).map(String.init).filter { $0.utf16.count > 2 })
        let candidateTokens = Set(candidate.split(separator: " ", omittingEmptySubsequences: false).map(String.init).filter { $0.utf16.count > 2 })
        if sourceTokens.isEmpty || candidateTokens.isEmpty { return similarity(source, candidate) }
        let shared = sourceTokens.intersection(candidateTokens).count
        return Float(shared) / Float(max(sourceTokens.count, candidateTokens.count))
    }

    static func containsPhrase(_ text: String, _ phrase: String) -> Bool { NetText.containsExact(" \(text) ", " \(phrase) ") }

    /// `title.split(Regex("""\s*[-–—|:]\s*"""), limit = 2)`.
    static func splitVideoTitle(_ title: String) -> [String] {
        let s = Array(title.unicodeScalars)
        let separators: Set<UInt32> = [0x2D, 0x2013, 0x2014, 0x7C, 0x3A]
        guard let sep = s.firstIndex(where: { separators.contains($0.value) }) else { return [title] }
        var start = sep
        while start > 0, NetText.isRegexSpace(s[start - 1]) { start -= 1 }
        var end = sep + 1
        while end < s.count, NetText.isRegexSpace(s[end]) { end += 1 }
        var first = String.UnicodeScalarView(), second = String.UnicodeScalarView()
        first.append(contentsOf: s[0..<start])
        second.append(contentsOf: s[end...])
        return [String(first), String(second)]
    }

    // MARK: Normalisation

    static let noiseWords = ["official", "lyric", "audio", "video", "hd", "mv"]
    static let trailingNoise = ["official music video", "official video", "official audio", "lyrics video", "lyric video",
                                "lyrics", "hd", "4k"]

    /// `normalize`: NFKD, lower case, marks dropped, bracketed "(official …)" noise and trailing "lyrics"/"hd"/…
    /// words removed, punctuation to spaces, whitespace collapsed. Non-Latin titles keep their letters.
    public static func normalize(_ raw: String) -> String {
        let folded = NetText.lowercased(raw.decomposedStringWithCompatibilityMapping)
        var s = Array(folded.unicodeScalars.filter { !NetText.isMark($0) })
        s = replaceBracketNoise(s)
        s = replaceTrailingNoise(s)
        // [^\p{L}\p{N}\s] → " "
        s = s.map { NetText.isLetter($0) || NetText.isNumber($0) || NetText.isRegexSpace($0) ? $0 : " " }
        // \s+ → " "
        var collapsed = String.UnicodeScalarView()
        var inSpace = false
        for c in s {
            if NetText.isRegexSpace(c) {
                if !inSpace { collapsed.append(" ") }
                inSpace = true
            } else {
                collapsed.append(c)
                inSpace = false
            }
        }
        return NetText.trim(String(collapsed))
    }

    /// `[\[(](?:official|lyric|audio|video|hd|mv)[^\])]*[\])]` → " ".
    private static func replaceBracketNoise(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if s[i] == "[" || s[i] == "(", let end = bracketNoiseEnd(s, i) {
                out.append(" ")
                i = end
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    private static func bracketNoiseEnd(_ s: [Unicode.Scalar], _ open: Int) -> Int? {
        let start = open + 1
        guard noiseWords.contains(where: { matches(s, start, $0) }) else { return nil }
        var j = start
        while j < s.count, s[j] != "]" && s[j] != ")" { j += 1 }
        return j < s.count ? j + 1 : nil
    }

    /// `\b(?:official music video|…|hd|4k)\b` → " " (ASCII word boundaries, alternatives in order).
    private static func replaceTrailingNoise(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if isBoundary(s, i) {
                var matchedEnd: Int?
                for word in trailingNoise where matches(s, i, word) {
                    let end = i + word.unicodeScalars.count
                    if isBoundary(s, end) {
                        matchedEnd = end
                        break
                    }
                }
                if let end = matchedEnd {
                    out.append(" ")
                    i = end
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    private static func isBoundary(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        let before = i > 0 && NetText.isWordChar(s[i - 1])
        let after = i < s.count && NetText.isWordChar(s[i])
        return before != after
    }

    private static func matches(_ s: [Unicode.Scalar], _ at: Int, _ word: String) -> Bool {
        var j = at
        for c in word.unicodeScalars {
            guard j < s.count, s[j] == c else { return false }
            j += 1
        }
        return true
    }

    /// Edit-distance similarity 0…1 over UTF-16 code units.
    public static func similarity(_ a: String, _ b: String) -> Float {
        let x = Array(a.utf16), y = Array(b.utf16)
        if x == y { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        let distance = levenshtein(x, y)
        let longest = max(x.count, y.count)
        return 1 - Float(distance) / Float(longest)
    }

    static func levenshtein(_ a: [UInt16], _ b: [UInt16]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        if a.isEmpty { return b.count }
        for i in 1...a.count {
            current[0] = i
            if !b.isEmpty {
                for j in 1...b.count {
                    let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                    current[j] = min(current[j - 1] + 1, previous[j] + 1, substitution)
                }
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
