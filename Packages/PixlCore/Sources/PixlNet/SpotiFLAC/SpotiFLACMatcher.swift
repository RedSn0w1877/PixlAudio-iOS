import Foundation

/// Deterministic track matching and ISRC verification for SpotiFLAC candidates.
public enum SpotiFLACMatcher {
    public static let exactISRCScore = 200
    public static let minimumAcceptScore = 85

    private static let unwantedVariants: [String] = [
        "live",
        "karaoke",
        "instrumental",
        "sped up",
        "slowed",
        "nightcore",
        "8d audio",
        "reverb",
        "cover",
        "tribute",
        "acappella",
        "a cappella"
    ]

    /// Normalizes a candidate ISRC string to a 12-character uppercase alphanumeric code, or `nil` if invalid.
    public static func normalizeISRC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard compact.count == 12 else { return nil }
        for scalar in compact.unicodeScalars {
            let isUpperAlpha = scalar.value >= 65 && scalar.value <= 90
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if !isUpperAlpha && !isDigit {
                return nil
            }
        }
        return compact
    }

    /// Strips diacritics, featuring credits, parentheticals, and punctuation, returning lowercase ASCII `[a-z0-9]`.
    public static func cleanString(_ str: String) -> String {
        var s = str.lowercased()
        s = stripDiacritics(s)

        for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
            if let range = s.range(of: marker) {
                s = String(s[..<range.lowerBound])
            }
        }

        s = stripBracketed(s, open: "(", close: ")")
        s = stripBracketed(s, open: "[", close: "]")
        s = stripBracketed(s, open: "{", close: "}")

        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Scores a lossless candidate against the target query.
    ///
    /// - Returns:
    ///   - `200` (`exactISRCScore`) when both target and candidate have matching normalized ISRCs.
    ///   - `0` when the candidate is unplayable, has a mismatched non-empty ISRC, is an unwanted variant
    ///     (live/karaoke/instrumental/etc. not present in target), or exceeds the duration tolerance (`> 12s`).
    ///   - `85...175` for metadata matches combining title, artist, and duration proximity.
    public static func scoreCandidate(
        _ candidate: SpotiFLACCandidate,
        target: SpotiFLACTrackQuery
    ) -> Int {
        guard candidate.playable else { return 0 }

        let targetISRC = normalizeISRC(target.isrc)
        let candidateISRC = normalizeISRC(candidate.isrc)
        if let targetISRC, let candidateISRC {
            if targetISRC == candidateISRC {
                return exactISRCScore
            }
            // Both ISRCs are known and differ: reject unless it's a re-issue with identical title/artist/duration,
            // which we score strictly below an ISRC match.
        }

        let targetTitleLower = target.title.lowercased()
        let candidateTitleLower = candidate.title.lowercased()
        for variant in unwantedVariants {
            if candidateTitleLower.contains(variant) && !targetTitleLower.contains(variant) {
                return 0
            }
        }

        if let candidateDurationMs = candidate.durationMs, candidateDurationMs > 0, target.durationMs > 0 {
            let diffMs = abs(candidateDurationMs - target.durationMs)
            if diffMs > 12_000 {
                return 0
            }
        }

        let cleanTargetTitle = cleanString(target.title)
        let cleanCandidateTitle = cleanString(candidate.title)
        guard !cleanTargetTitle.isEmpty, !cleanCandidateTitle.isEmpty else { return 0 }

        var score = 0
        if cleanTargetTitle == cleanCandidateTitle {
            score += 100
        } else if cleanTargetTitle.count >= 4 && cleanCandidateTitle.count >= 4 &&
                    (cleanCandidateTitle.contains(cleanTargetTitle) || cleanTargetTitle.contains(cleanCandidateTitle)) {
            score += 65
        } else {
            return 0
        }

        let targetArtists = splitArtists(target.artist)
        let candidateArtists = candidate.artistNames.isEmpty
            ? splitArtists(candidate.artist)
            : candidate.artistNames.flatMap(splitArtists)

        var artistMatched = false
        for targetArtist in targetArtists where !targetArtist.isEmpty {
            for candidateArtist in candidateArtists where !candidateArtist.isEmpty {
                if targetArtist == candidateArtist ||
                    (targetArtist.count >= 3 && candidateArtist.count >= 3 &&
                     (candidateArtist.contains(targetArtist) || targetArtist.contains(candidateArtist))) {
                    artistMatched = true
                    break
                }
            }
            if artistMatched { break }
        }
        guard artistMatched else { return 0 }
        score += 50

        if let candidateDurationMs = candidate.durationMs, candidateDurationMs > 0, target.durationMs > 0 {
            let diffMs = abs(candidateDurationMs - target.durationMs)
            if diffMs <= 3_000 {
                score += 25
            } else if diffMs <= 7_000 {
                score += 10
            }
        }

        if let targetISRC, let candidateISRC, targetISRC != candidateISRC {
            // Penalize known-different ISRC (e.g. compilation vs studio album) so an exact ISRC always wins.
            score -= 15
        }

        return max(0, score)
    }

    /// Selects the highest-scoring candidate that meets or exceeds `minimumAcceptScore`.
    public static func selectBestCandidate(
        _ candidates: [SpotiFLACCandidate],
        target: SpotiFLACTrackQuery
    ) -> (candidate: SpotiFLACCandidate, score: Int)? {
        var best: (candidate: SpotiFLACCandidate, score: Int)?
        for candidate in candidates {
            let score = scoreCandidate(candidate, target: target)
            guard score >= minimumAcceptScore else { continue }
            if let currentBest = best {
                if score > currentBest.score {
                    best = (candidate, score)
                }
            } else {
                best = (candidate, score)
            }
            if score == exactISRCScore {
                break
            }
        }
        return best
    }

    private static func splitArtists(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;&/")
        let parts = raw.components(separatedBy: separators)
        var cleaned: [String] = []
        for part in parts {
            let c = cleanString(part)
            if !c.isEmpty {
                cleaned.append(c)
            }
        }
        let whole = cleanString(raw)
        if !whole.isEmpty && !cleaned.contains(whole) {
            cleaned.append(whole)
        }
        return cleaned
    }

    private static func stripDiacritics(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if !(0x0300...0x036F).contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func stripBracketed(_ s: String, open: Character, close: Character) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var depth = 0
        for ch in s {
            if ch == open {
                depth += 1
            } else if ch == close && depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }
}
