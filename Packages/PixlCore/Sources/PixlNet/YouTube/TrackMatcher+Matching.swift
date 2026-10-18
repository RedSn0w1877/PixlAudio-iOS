// Live matching on top of the Android-port `TrackMatcher.score` (kept untouched: golden vectors pin it). Spotify
// titles carry "(with X)", "- 2011 Remaster" and the like while YouTube Music's do not (or the other way round);
// the legacy score rejects those pairs outright (title similarity under 0.55). `matchScore` is what the matcher
// really ranks candidates with: the legacy score or this lenient one, whichever is higher.

import Foundation

extension TrackMatcher {
    /// Edit-style phrases that describe the same recording (never a different one): dropped before comparing titles.
    static let editionPhrases = ["radio edit", "single edit", "single version", "album version", "original version",
                                 "deluxe", "explicit", "clean", "bonus track", "mono", "stereo", "anniversary",
                                 "expanded"]
    static let creditPrefixes = ["feat", "ft", "featuring", "with", "prod", "produced", "from"]
    static let creditMarkers = [" feat. ", " feat ", " ft. ", " ft ", " featuring "]
    static let dashSeparators = [" - ", " \u{2013} ", " \u{2014} "]

    /// The higher of the Android-port score and the lenient one.
    public static func matchScore(_ song: MatchableTrack, _ candidate: YouTubeSearchResult) -> Float {
        max(score(song, candidate), scoreForMatching(song, candidate))
    }

    /// `score` with: credits/editions stripped from both titles, "Artist - Title" and "Title - Artist" video titles,
    /// any credited artist counting, and a 9-20 s duration gap neutral (radio edit, video intro) instead of a penalty
    /// that makes a perfect title+artist impossible to accept.
    public static func scoreForMatching(_ song: MatchableTrack, _ candidate: YouTubeSearchResult) -> Float {
        var score: Float = 0

        let songTitle = cleanTitle(song.title)
        let credited = song.artist.split(separator: ",").map { normalize(String($0)) }.filter { !NetText.isBlank($0) }
        let primaryArtist = normalize(NetText.substringBefore(song.artist, ","))

        let rawCandidate = stripCredits(candidate.title)
        let parts = splitVideoTitle(rawCandidate)
        var titleRaw = rawCandidate
        var hasExactVideoArtist = false
        if candidate.isMusicVideo, parts.count == 2 {
            if NetText.same(normalize(parts[0]), primaryArtist) {
                titleRaw = parts[1]
                hasExactVideoArtist = true
            } else if NetText.same(normalize(parts[1]), primaryArtist) {
                titleRaw = parts[0]
                hasExactVideoArtist = true
            }
        }
        let candidateTitle = cleanTitle(titleRaw)
        let titleSimilarity = similarity(songTitle, candidateTitle)
        score += titleSimilarity * titleWeight

        var candidateArtist = normalize(candidate.artist)
        candidateArtist = NetText.removeSuffix(candidateArtist, " topic")
        candidateArtist = NetText.removeSuffix(candidateArtist, "vevo")
        candidateArtist = NetText.trim(candidateArtist)
        var artistScore: Float = hasExactVideoArtist ? 0.9 : 0
        for artist in credited { artistScore = max(artistScore, artistSimilarity(artist, candidateArtist)) }
        if titleSimilarity < 0.55 || artistScore < 0.65 { return 0 }
        score += artistScore * artistWeight

        let expectedSeconds = Int(Int32(truncatingIfNeeded: song.durationMs / 1000))
        if let actualSeconds = candidate.durationSeconds, expectedSeconds > 0 {
            let difference = abs(actualSeconds - expectedSeconds)
            if difference <= exactDurationToleranceSeconds {
                score += durationWeight
            } else if difference <= looseDurationToleranceSeconds {
                score += durationWeight * 0.5
            } else if difference > 20 {
                score += -durationWeight
            }
        }

        if let album = candidate.album, !NetText.isBlank(album),
           similarity(cleanTitle(song.album), cleanTitle(album)) > 0.85 {
            score += albumBonus
        }

        for word in variantPenaltyWords {
            if containsPhrase(candidateTitle, word) && !containsPhrase(songTitle, word) { score -= variantPenalty }
        }
        return min(max(score, 0), 1)
    }

    /// A title as the matcher compares it: credits, remaster/edition tags and noise gone, then `normalize`.
    /// "Live", "remix", "acoustic"… stay, so variants are still told apart.
    public static func cleanTitle(_ raw: String) -> String {
        let cleaned = normalize(stripCredits(raw))
        return cleaned.isEmpty ? normalize(raw) : cleaned
    }

    /// Removes "(feat. X)", "(with X)", "[2011 Remaster]", "- Remastered 2011", "- Radio Edit" and a trailing
    /// "ft. X" from a raw title.
    static func stripCredits(_ raw: String) -> String {
        var s = stripEditionBrackets(raw)
        s = stripDashEdition(s)
        var cut: String.Index?
        for marker in creditMarkers {
            if let r = s.range(of: marker, options: .caseInsensitive), cut == nil || r.lowerBound < cut! {
                cut = r.lowerBound
            }
        }
        if let cut, !NetText.isBlank(String(s[..<cut])) { s = String(s[..<cut]) }
        return s
    }

    /// Whether a bracketed/dash-trailing fragment only describes credits or an edition of the same recording.
    static func isEditionPhrase(_ fragment: String) -> Bool {
        let n = normalize(fragment)
        if n.isEmpty { return false }
        for word in variantPenaltyWords where containsPhrase(n, word) { return false }
        if n.contains("remaster") { return true }
        for prefix in creditPrefixes where n == prefix || n.hasPrefix(prefix + " ") { return true }
        for phrase in editionPhrases where containsPhrase(n, phrase) { return true }
        return false
    }

    private static func stripEditionBrackets(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" {
                let close: Character = c == "(" ? ")" : "]"
                if let j = chars[(i + 1)...].firstIndex(of: close), isEditionPhrase(String(chars[(i + 1)..<j])) {
                    out.append(" ")
                    i = j + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func stripDashEdition(_ s: String) -> String {
        var current = s
        while true {
            var last: Range<String.Index>?
            for separator in dashSeparators {
                if let r = current.range(of: separator, options: .backwards), last == nil || r.lowerBound > last!.lowerBound {
                    last = r
                }
            }
            guard let last, isEditionPhrase(String(current[last.upperBound...])),
                  !NetText.isBlank(String(current[..<last.lowerBound])) else { return current }
            current = String(current[..<last.lowerBound])
        }
    }
}
