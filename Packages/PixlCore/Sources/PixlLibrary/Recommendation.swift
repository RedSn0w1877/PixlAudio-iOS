// Port of `data/recommendation/MusicRecommendationEngine.kt`, `Muselle.kt` (Muselle / Muselle 2),
// `HomeRecommendationPlanner.kt` and the pure part of `data/DailyMixManager.kt` (`personalizedPicks` and the day
// seeds). Scores are computed with the same operations in the same order as Kotlin, including the
// `java.util.Random` jitter seeded from `String.hashCode()`, so rankings match Android bit for bit.
//
// One Kotlin detail needs an explicit input on iOS: `rank` counts a stored feedback *object* once even when it is
// reachable from two song ids (the numeric id and its `spotify_<id>` alias), while genuinely separate histories
// with equal counters are both counted. Swift values have no identity, so callers pass the key each value was read
// from (`signalSources` / `historySources`); `RecommendationInputs.resolve` builds them the way Android does.

import Foundation
import PixlFoundation
import PixlModel

/// Kotlin `Double.compareTo` (total order: -0.0 < 0.0, NaN above everything).
@inlinable
func javaDoubleCompare(_ a: Double, _ b: Double) -> Int {
    if a < b { return -1 }
    if a > b { return 1 }
    if a.isNaN || b.isNaN { return a.isNaN ? (b.isNaN ? 0 : 1) : -1 }
    if a == 0 && b == 0 {
        if a.sign == b.sign { return 0 }
        return a.sign == .minus ? -1 : 1
    }
    return 0
}

public enum MusicRecommendationEngine {
    /// Learned playback feedback for one song (Android `Signal`).
    public struct Signal: Sendable, Hashable, Codable {
        public var sessions: Int
        public var completions: Int
        public var earlySkips: Int
        public var voluntaryPlays: Int
        public var lastPlayedMs: Int64
        public var listenedMs: Int64

        public init(sessions: Int = 0, completions: Int = 0, earlySkips: Int = 0, voluntaryPlays: Int = 0,
                    lastPlayedMs: Int64 = 0, listenedMs: Int64 = 0) {
            self.sessions = sessions
            self.completions = completions
            self.earlySkips = earlySkips
            self.voluntaryPlays = voluntaryPlays
            self.lastPlayedMs = lastPlayedMs
            self.listenedMs = listenedMs
        }
    }

    /// Play-count history for one song (Android `History`, from the engagement table).
    public struct History: Sendable, Hashable, Codable {
        public var plays: Int
        public var listenedMs: Int64
        public var lastPlayedMs: Int64

        public init(plays: Int = 0, listenedMs: Int64 = 0, lastPlayedMs: Int64 = 0) {
            self.plays = plays
            self.listenedMs = listenedMs
            self.lastPlayedMs = lastPlayedMs
        }
    }

    /// A ranked song with its score and the human-readable reason.
    public struct Pick: Sendable, Hashable {
        public var song: Song
        public var score: Double
        public var reason: String
        public var unheard: Bool

        public init(song: Song, score: Double, reason: String, unheard: Bool) {
            self.song = song
            self.score = score
            self.reason = reason
            self.unheard = unheard
        }
    }

    /// Reasons that explain why a song appears *less*; never show them on the card recommending it.
    public static let reasonPrefixDemoted = "Less often"
    static let day: Int64 = 86_400_000

    /// `record`: folds one listening session into the feedback. Sessions under 5 s are ignored.
    public static func record(_ previous: Signal, listenedMs: Int64, durationMs: Int64, voluntary: Bool,
                              changedTrack: Bool, nowMs: Int64) -> Signal {
        if listenedMs < 5_000 { return previous }
        let completed = durationMs > 0 && Double(listenedMs) / Double(durationMs) >= 0.8
        let skipped = changedTrack && durationMs > 0 && listenedMs < min(30_000, durationMs / 3)
        var next = previous
        next.sessions = min(previous.sessions + 1, 1_000_000)
        next.completions = previous.completions + (completed ? 1 : 0)
        next.earlySkips = previous.earlySkips + (skipped ? 1 : 0)
        next.voluntaryPlays = previous.voluntaryPlays + (voluntary ? 1 : 0)
        next.lastPlayedMs = max(previous.lastPlayedMs, nowMs)
        next.listenedMs = previous.listenedMs &+ max(listenedMs, 0)
        return next
    }

    private struct Candidate {
        let song: Song
        let keys: SongKeys
        let favorite: Bool
        let signal: Signal
        let history: History
    }

    /// The normalised keys of a song, computed once (NFKC normalisation is the expensive part of ranking).
    struct SongKeys: Sendable {
        let artist: String
        let recording: String
        let genre: String?
        let album: String
        let albumIsBlank: Bool

        init(_ song: Song) {
            let artistNormalized = normalize(song.artist)
            artist = artistNormalized.isKotlinBlank ? "unknown:\(song.id)" : artistNormalized
            recording = "\(artist)|\(normalize(song.title))"
            genre = genreKey(song)
            album = normalize(song.album)
            albumIsBlank = song.album.isKotlinBlank
        }
    }

    /// A pick with its keys, for repeated selections over the same ranking.
    struct KeyedPick: Sendable {
        let pick: Pick
        let keys: SongKeys
    }

    /// `rank`: scores every distinct recording (duplicates across sources merge their evidence) and sorts by score,
    /// then id. `signalSources`/`historySources` map a song id to the stored key its value came from (default: the
    /// song id itself, i.e. every entry is a separate record).
    public static func rank(songs: [Song], favorites: Set<String>, signals: [String: Signal],
                            history: [String: History], nowMs: Int64, seed: Int64,
                            signalSources: [String: String] = [:], historySources: [String: String] = [:]) -> [Pick] {
        rankKeyed(songs: songs, favorites: favorites, signals: signals, history: history, nowMs: nowMs, seed: seed,
                  signalSources: signalSources, historySources: historySources).map(\.pick)
    }

    static func rankKeyed(songs: [Song], favorites: Set<String>, signals: [String: Signal],
                          history: [String: History], nowMs: Int64, seed: Int64,
                          signalSources: [String: String], historySources: [String: String]) -> [KeyedPick] {
        let favoriteKeys = Set(favorites.map(KotlinKey.init))
        let signalMap = keyed(signals), historyMap = keyed(history)
        let signalSourceMap = keyed(signalSources), historySourceMap = keyed(historySources)

        var groupOrder: [KotlinKey] = []
        var groups: [KotlinKey: (keys: SongKeys, versions: [Song])] = [:]
        for song in songs.filter({ !$0.title.isKotlinBlank }).kotlinDistinct(by: \.id) {
            let keys = SongKeys(song)
            let key = KotlinKey(keys.recording)
            if groups[key] == nil {
                groupOrder.append(key)
                groups[key] = (keys, [song])
            } else {
                groups[key]!.versions.append(song)
            }
        }
        let candidates = groupOrder.map { groupKey -> Candidate in
            let (keys, versions) = groups[groupKey]!
            let signalValues = distinctInstances(versions.compactMap { v in
                signalMap[KotlinKey(v.id)].map { ($0, signalSourceMap[KotlinKey(v.id)] ?? v.id) }
            })
            let historyValues = distinctInstances(versions.compactMap { v in
                historyMap[KotlinKey(v.id)].map { ($0, historySourceMap[KotlinKey(v.id)] ?? v.id) }
            })
            return Candidate(song: versions[0], keys: keys,
                             favorite: versions.contains { favoriteKeys.contains(KotlinKey($0.id)) || $0.isFavorite },
                             signal: mergeSignals(signalValues), history: mergeHistory(historyValues))
        }

        var artistWeights = OrderedStringMap<Double>()
        var genreWeights = OrderedStringMap<Double>()
        for candidate in candidates {
            let signal = candidate.signal, past = candidate.history
            let engaged = max(signal.lastPlayedMs, past.lastPlayedMs)
            let lastEngaged = engaged > 0 ? engaged : nowMs
            let ageDays = Double(max(nowMs &- lastEngaged, 0)) / Double(day)
            let decay = 1.0 / (1.0 + ageDays / 45.0)
            var raw = candidate.favorite ? 2.0 : 0.0
            raw = raw + log(1.0 + Double(max(past.plays, 0))) * 0.3
            raw = raw + Double(signal.completions) * 0.8
            raw = raw + Double(signal.voluntaryPlays) * 0.2
            raw = raw - Double(signal.earlySkips) * 1.1
            let weight = raw.coerced(in: -4.0, 6.0) * decay
            let artist = candidate.keys.artist
            artistWeights[artist] = artistWeights[artist].map { $0 + weight } ?? weight
            if let genre = candidate.keys.genre {
                genreWeights[genre] = genreWeights[genre].map { $0 + weight } ?? weight
            }
        }
        let artistScale = maxAbs(artistWeights.values).map { max($0, 1.0) } ?? 1.0
        let genreScale = maxAbs(genreWeights.values).map { max($0, 1.0) } ?? 1.0
        let maxPlays = candidates.map(\.history.plays).max() ?? 1
        let playScale = log(1.0 + Double(max(maxPlays, 1)))

        let picks = candidates.map { candidate -> KeyedPick in
            let song = candidate.song, signal = candidate.signal, past = candidate.history
            let favorite = candidate.favorite
            let artist = (artistWeights[candidate.keys.artist] ?? 0.0) / artistScale
            let genre = (candidate.keys.genre.flatMap { genreWeights[$0] } ?? 0.0) / genreScale
            let taste = artist * 0.75 + genre * 0.25
            let satisfaction = (Double(signal.completions) + 2.0) / (Double(signal.sessions) + 4.0)
            let skipRate = Double(signal.earlySkips) / (Double(signal.sessions) + 2.0)
            let familiarity = log(1.0 + Double(max(past.plays, 0))) / playScale
            let lastPlayed = max(signal.lastPlayedMs, past.lastPlayedMs)
            let hoursAgo = lastPlayed == 0 ? 1_000.0 : Double(max(nowMs &- lastPlayed, 0)) / 3_600_000.0
            let fatigue = (1.0 - hoursAgo / 24.0).coerced(in: 0.0, 1.0)
            let unheard = past.plays == 0 && signal.sessions == 0
            let exploration = 1.0 / (1.0 + Double(max(past.plays, 0)) + Double(signal.sessions)).squareRoot()
            var random = JavaRandom(seed: seed ^ Int64(KotlinText.hashCode(candidate.keys.recording)))
            let jitter = random.nextDouble() * 0.025
            var score = taste * 0.32
            score = score + satisfaction * 0.2
            score = score + familiarity * 0.12
            score = score + (favorite ? 0.18 : 0.0)
            score = score + exploration * 0.12
            score = score - skipRate * 0.55
            score = score - fatigue * 0.2
            score = score + jitter
            let reason: String
            if skipRate > 0.4 { reason = "\(reasonPrefixDemoted): frequently skipped" }
            else if favorite { reason = "One of your favorites" }
            else if signal.completions >= 2 { reason = "You often finish this song" }
            else if unheard && artist > 0.1 { reason = "Discover more from an artist you enjoy" }
            else if unheard && genre > 0.1 { reason = "Explore a genre you enjoy" }
            else if unheard { reason = "Something you haven't played yet" }
            else if fatigue > 0.8 { reason = "Played recently" }
            else { reason = "Based on your listening history" }
            return KeyedPick(pick: Pick(song: song, score: score, reason: reason, unheard: unheard), keys: candidate.keys)
        }
        return sortByScore(picks)
    }

    static func sortByScore(_ picks: [KeyedPick]) -> [KeyedPick] {
        picks.kotlinSorted {
            chain(javaDoubleCompare($1.pick.score, $0.pick.score), KotlinText.compare($0.pick.song.id, $1.pick.song.id))
        }
    }

    private static func keyed<V>(_ map: [String: V]) -> [KotlinKey: V] {
        var out: [KotlinKey: V] = [:]
        for (k, v) in map { out[KotlinKey(k)] = v }
        return out
    }

    private static func maxAbs(_ values: [Double]) -> Double? {
        var best: Double?
        for v in values.map(abs) { best = best.map { Swift.max($0, v) } ?? v }
        return best
    }

    /// Counts each stored record once (Kotlin's identity-based `distinctInstances`).
    private static func distinctInstances<T>(_ values: [(T, String)]) -> [T] {
        if values.count <= 1 { return values.map(\.0) }
        var seen = Set<KotlinKey>()
        return values.filter { seen.insert(KotlinKey($0.1)).inserted }.map(\.0)
    }

    private static func sumCounts(_ values: [Int]) -> Int {
        let total = values.reduce(Int64(0)) { $0 &+ Int64(max($1, 0)) }
        return Int(min(total, Int64(Int32.max)))
    }

    private static func mergeSignals(_ values: [Signal]) -> Signal {
        if values.count == 1 { return values[0] }
        return Signal(sessions: sumCounts(values.map(\.sessions)), completions: sumCounts(values.map(\.completions)),
                      earlySkips: sumCounts(values.map(\.earlySkips)), voluntaryPlays: sumCounts(values.map(\.voluntaryPlays)),
                      lastPlayedMs: values.map(\.lastPlayedMs).max() ?? 0,
                      listenedMs: values.reduce(Int64(0)) { $0 &+ max($1.listenedMs, 0) })
    }

    private static func mergeHistory(_ values: [History]) -> History {
        if values.count == 1 { return values[0] }
        return History(plays: sumCounts(values.map(\.plays)),
                       listenedMs: values.reduce(Int64(0)) { $0 &+ max($1.listenedMs, 0) },
                       lastPlayedMs: values.map(\.lastPlayedMs).max() ?? 0)
    }

    /// `select`: picks `limit` songs, reserving exploration slots for unheard songs (`explorationFraction`,
    /// clamped to 0…0.6) and penalising repeated or back-to-back artists and albums.
    public static func select(_ ranked: [Pick], limit: Int, explorationFraction: Float = 0.25) -> [Pick] {
        if limit <= 0 { return [] }
        return selectKeyed(ranked.map { KeyedPick(pick: $0, keys: SongKeys($0.song)) }, limit: limit,
                           explorationFraction: explorationFraction).map(\.pick)
    }

    static func selectKeyed(_ ranked: [KeyedPick], limit: Int, explorationFraction: Float = 0.25) -> [KeyedPick] {
        if limit <= 0 { return [] }
        let remaining = ranked.kotlinDistinct { $0.keys.recording }
        // Artists and albums as small integers so the selection loop does no hashing.
        var artistIds: [KotlinKey: Int] = [:]
        var albumIds: [KotlinKey: Int] = [:]
        let artistOf = remaining.map { item -> Int in
            let k = KotlinKey(item.keys.artist)
            if let id = artistIds[k] { return id }
            artistIds[k] = artistIds.count
            return artistIds.count - 1
        }
        let albumOf = remaining.map { item -> Int in
            let k = KotlinKey(item.keys.album)
            if let id = albumIds[k] { return id }
            albumIds[k] = albumIds.count
            return albumIds.count - 1
        }
        var alive = [Bool](repeating: true, count: remaining.count)
        var aliveUnheard = remaining.filter(\.pick.unheard).count
        var counts = [Int](repeating: 0, count: artistIds.count)
        var selected: [KeyedPick] = []
        var previous: Int?
        let target = min(limit, remaining.count)
        let discoveryTarget = Int(KotlinMath.toInt(Float(target) * explorationFraction.coerced(in: 0, 0.6)))
        var discoveries = 0
        for slot in 0..<target {
            let needsDiscovery = discoveries < discoveryTarget
                && (slot % 3 == 2 || target - slot <= discoveryTarget - discoveries)
            let onlyUnheard = needsDiscovery && aliveUnheard > 0
            var bestIndex: Int?
            var bestValue = 0.0
            for index in remaining.indices where alive[index] {
                let item = remaining[index]
                if onlyUnheard && !item.pick.unheard { continue }
                let artist = artistOf[index]
                var value = item.pick.score - Double(counts[artist]) * 0.17
                let sameArtist = previous.map { artistOf[$0] == artist } ?? false
                value -= sameArtist ? 0.3 : 0.0
                if let previous, !item.keys.albumIsBlank, albumOf[index] == albumOf[previous], sameArtist {
                    value -= 0.1
                } else {
                    value -= 0.0
                }
                if bestIndex == nil || javaDoubleCompare(bestValue, value) < 0 {
                    bestIndex = index
                    bestValue = value
                }
            }
            guard let chosen = bestIndex else { continue }
            alive[chosen] = false
            let next = remaining[chosen]
            if next.pick.unheard { aliveUnheard -= 1 }
            selected.append(next)
            counts[artistOf[chosen]] += 1
            previous = chosen
            if next.pick.unheard { discoveries += 1 }
        }
        return selected
    }

    /// The artist identity: the normalised artist, or `unknown:<id>` when blank.
    public static func artistKey(_ song: Song) -> String {
        let n = normalize(song.artist)
        return n.isKotlinBlank ? "unknown:\(song.id)" : n
    }

    static func genreKey(_ song: Song) -> String? {
        guard let genre = song.genre else { return nil }
        let n = normalize(genre)
        return n.isKotlinBlank || KotlinText.equals(n, "unknown") ? nil : n
    }

    /// The recording identity across sources: `artistKey|normalised title`.
    public static func recordingKey(_ song: Song) -> String { "\(artistKey(song))|\(normalize(song.title))" }

    /// NFKC, lower-cased (ROOT), whitespace runs collapsed, trimmed.
    public static func normalize(_ value: String) -> String {
        KotlinText.collapseJavaWhitespace(KotlinText.lowercase(KotlinText.nfkc(value))).kotlinTrimmed()
    }
}

// MARK: - Muselle

/// The recommendation tiers: Muselle (on-device baseline) and Muselle 2 (the Plus reranker).
public enum MuselleVariant: String, Sendable, Hashable, CaseIterable {
    case basic = "BASIC"
    case plus = "PLUS"
}

public enum Muselle {
    public static func rank(_ variant: MuselleVariant, songs: [Song], favorites: Set<String>,
                            signals: [String: MusicRecommendationEngine.Signal],
                            history: [String: MusicRecommendationEngine.History], nowMs: Int64, seed: Int64,
                            signalSources: [String: String] = [:], historySources: [String: String] = [:])
        -> [MusicRecommendationEngine.Pick]
    {
        rankKeyed(variant, songs: songs, favorites: favorites, signals: signals, history: history, nowMs: nowMs,
                  seed: seed, signalSources: signalSources, historySources: historySources).map(\.pick)
    }

    static func rankKeyed(_ variant: MuselleVariant, songs: [Song], favorites: Set<String>,
                          signals: [String: MusicRecommendationEngine.Signal],
                          history: [String: MusicRecommendationEngine.History], nowMs: Int64, seed: Int64,
                          signalSources: [String: String], historySources: [String: String])
        -> [MusicRecommendationEngine.KeyedPick]
    {
        switch variant {
        case .basic:
            MusicRecommendationEngine.rankKeyed(songs: songs, favorites: favorites, signals: signals, history: history,
                                                nowMs: nowMs, seed: seed, signalSources: signalSources,
                                                historySources: historySources)
        case .plus:
            Muselle2.rankKeyed(songs: songs, favorites: favorites, signals: signals, history: history, nowMs: nowMs,
                               seed: seed, signalSources: signalSources, historySources: historySources)
        }
    }
}

/// Muselle 2: reranks the baseline for context, novelty, duration fit, era and diversity.
public enum Muselle2 {
    public static func rank(songs: [Song], favorites: Set<String>, signals: [String: MusicRecommendationEngine.Signal],
                            history: [String: MusicRecommendationEngine.History], nowMs: Int64, seed: Int64,
                            signalSources: [String: String] = [:], historySources: [String: String] = [:])
        -> [MusicRecommendationEngine.Pick]
    {
        rankKeyed(songs: songs, favorites: favorites, signals: signals, history: history, nowMs: nowMs, seed: seed,
                  signalSources: signalSources, historySources: historySources).map(\.pick)
    }

    static func rankKeyed(songs: [Song], favorites: Set<String>, signals: [String: MusicRecommendationEngine.Signal],
                          history: [String: MusicRecommendationEngine.History], nowMs: Int64, seed: Int64,
                          signalSources: [String: String], historySources: [String: String])
        -> [MusicRecommendationEngine.KeyedPick]
    {
        let baseline = MusicRecommendationEngine.rankKeyed(songs: songs, favorites: favorites, signals: signals,
                                                           history: history, nowMs: nowMs, seed: seed,
                                                           signalSources: signalSources, historySources: historySources)
        if baseline.count < 2 { return baseline }
        var artistCounts: [KotlinKey: Int] = [:]
        var genreCounts: [KotlinKey: Int] = [:]
        for item in baseline {
            artistCounts[KotlinKey(item.keys.artist), default: 0] += 1
            genreCounts[KotlinKey(genreKey(item.pick.song)), default: 0] += 1
        }
        let durations = baseline.map(\.pick.song.duration).filter { $0 > 0 }.sorted()
        let medianDuration = durations.isEmpty ? 0 : durations[durations.count / 2]
        let maxYearRaw = baseline.map(\.pick.song.year).max() ?? 0
        let maxYear = maxYearRaw > 0 ? maxYearRaw : 0
        let reranked = baseline.map { item -> MusicRecommendationEngine.KeyedPick in
            let pick = item.pick, song = pick.song
            let artistPenalty = Double((artistCounts[KotlinKey(item.keys.artist)] ?? 1) - 1) * 0.035
            let genre = genreKey(song)
            let genrePenalty = genre.isKotlinBlank ? 0.0 : Double((genreCounts[KotlinKey(genre)] ?? 1) - 1) * 0.012
            let durationFit: Double
            if medianDuration > 0 && song.duration > 0 {
                durationFit = (1.0 - Double(abs(song.duration - medianDuration)) / Double(medianDuration))
                    .coerced(in: -1.0, 1.0) * 0.06
            } else {
                durationFit = 0.0
            }
            let eraBoost: Double
            if maxYear > 0 && song.year > 0 {
                eraBoost = (1.0 - Double(abs(song.year - maxYear)) / 40.0).coerced(in: -1.0, 1.0) * 0.025
            } else {
                eraBoost = 0.0
            }
            let noveltyBoost = pick.unheard ? 0.045 : 0.0
            var score = pick.score + durationFit
            score = score + eraBoost
            score = score + noveltyBoost
            score = score - artistPenalty
            score = score - genrePenalty
            let reason: String
            if pick.unheard && noveltyBoost > 0 { reason = "A fresh pick shaped by your listening patterns" }
            else if durationFit > 0.035 { reason = "Fits the length of your usual listening sessions" }
            else if artistPenalty > 0.07 { reason = "Balanced into the queue for more artist variety" }
            else { reason = pick.reason }
            var updated = pick
            updated.score = score
            updated.reason = reason
            return MusicRecommendationEngine.KeyedPick(pick: updated, keys: item.keys)
        }
        return MusicRecommendationEngine.sortByScore(reranked)
    }

    private static func genreKey(_ song: Song) -> String {
        song.genre.map { KotlinText.lowercase($0.kotlinTrimmed()) } ?? ""
    }

    /// `Muselle2.select`.
    public static func select(songs: [Song], favorites: Set<String>, signals: [String: MusicRecommendationEngine.Signal],
                              history: [String: MusicRecommendationEngine.History], nowMs: Int64, seed: Int64,
                              limit: Int, explorationFraction: Float = 0.3) -> [Song] {
        let ranked = rankKeyed(songs: songs, favorites: favorites, signals: signals, history: history, nowMs: nowMs,
                               seed: seed, signalSources: [:], historySources: [:])
        return MusicRecommendationEngine.selectKeyed(ranked, limit: limit, explorationFraction: explorationFraction)
            .map(\.pick.song)
    }
}

// MARK: - Inputs

/// The recommendation inputs resolved for a library the way `DailyMixManager.personalizedPicks` and
/// `HomeDiscoveryStateHolder` do: each song reads its stored record by id, falling back to `spotify_<spotifyId>`.
public struct RecommendationInputs: Sendable {
    public var signals: [String: MusicRecommendationEngine.Signal]
    public var history: [String: MusicRecommendationEngine.History]
    public var signalSources: [String: String]
    public var historySources: [String: String]

    public static func resolve(library: [Song], storedSignals: [String: MusicRecommendationEngine.Signal],
                               storedHistory: [String: MusicRecommendationEngine.History]) -> RecommendationInputs {
        var signalStore: [KotlinKey: MusicRecommendationEngine.Signal] = [:]
        for (k, v) in storedSignals { signalStore[KotlinKey(k)] = v }
        var historyStore: [KotlinKey: MusicRecommendationEngine.History] = [:]
        for (k, v) in storedHistory { historyStore[KotlinKey(k)] = v }
        var result = RecommendationInputs(signals: [:], history: [:], signalSources: [:], historySources: [:])
        for song in library {
            let alias = "spotify_\(song.spotifyId ?? "null")"
            if let s = signalStore[KotlinKey(song.id)] {
                result.signals[song.id] = s
                result.signalSources[song.id] = "stored:\(song.id)"
            } else if let s = signalStore[KotlinKey(alias)] {
                result.signals[song.id] = s
                result.signalSources[song.id] = "stored:\(alias)"
            } else {
                result.signals[song.id] = MusicRecommendationEngine.Signal()
                result.signalSources[song.id] = "default:\(song.id)"
            }
            if let h = historyStore[KotlinKey(song.id)] {
                result.history[song.id] = h
                result.historySources[song.id] = "stored:\(song.id)"
            } else if let h = historyStore[KotlinKey(alias)] {
                result.history[song.id] = h
                result.historySources[song.id] = "stored:\(alias)"
            } else {
                result.history[song.id] = MusicRecommendationEngine.History()
                result.historySources[song.id] = "default:\(song.id)"
            }
        }
        return result
    }
}

// MARK: - Daily Mix

/// Per-song play statistics (Android `SongEngagementEntity` / `DailyMixManager.SongEngagementStats`).
public struct EngagementStats: Sendable, Hashable, Codable {
    public var playCount: Int
    public var totalPlayDurationMs: Int64
    public var lastPlayedTimestamp: Int64

    public init(playCount: Int = 0, totalPlayDurationMs: Int64 = 0, lastPlayedTimestamp: Int64 = 0) {
        self.playCount = playCount
        self.totalPlayDurationMs = totalPlayDurationMs
        self.lastPlayedTimestamp = lastPlayedTimestamp
    }

    public var history: MusicRecommendationEngine.History {
        MusicRecommendationEngine.History(plays: playCount, listenedMs: totalPlayDurationMs, lastPlayedMs: lastPlayedTimestamp)
    }
}

public enum DailyMix {
    /// The Daily Mix seed: the local epoch day.
    public static func dailySeed(epochDay: Int64) -> Int64 { epochDay }

    /// The AI candidate list seed (`getTopCandidatesForAi`).
    public static func aiCandidatesSeed(epochDay: Int64) -> Int64 { epochDay + 42 }

    /// The Your Mix seed: `java.util.Random(year * 1000 + dayOfYear + 17).nextLong()`.
    public static func yourMixSeed(year: Int, dayOfYear: Int) -> Int64 {
        var random = JavaRandom(seed: Int64(Int32(truncatingIfNeeded: year * 1000 + dayOfYear + 17)))
        return random.nextLong()
    }

    /// `personalizedPicks`: Daily Mix / Your Mix selection from the library, the engagement table and the stored
    /// feedback (`exploration` is the user's exploration setting, default 0.25).
    public static func personalizedPicks(allSongs: [Song], favoriteSongIds: Set<String>,
                                         engagements: [String: EngagementStats],
                                         storedSignals: [String: MusicRecommendationEngine.Signal],
                                         exploration: Float = 0.25, nowMs: Int64, limit: Int = 30,
                                         seed: Int64) -> [MusicRecommendationEngine.Pick] {
        if allSongs.isEmpty || limit <= 0 { return [] }
        let inputs = RecommendationInputs.resolve(library: allSongs, storedSignals: storedSignals,
                                                  storedHistory: engagements.mapValues(\.history))
        let favoriteKeys = Set(favoriteSongIds.map(KotlinKey.init))
        var favorites = favoriteSongIds
        for song in allSongs where favoriteKeys.contains(KotlinKey("spotify_\(song.spotifyId ?? "null")")) {
            favorites.insert(song.id)
        }
        let ranked = MusicRecommendationEngine.rankKeyed(songs: allSongs, favorites: favorites, signals: inputs.signals,
                                                    history: inputs.history, nowMs: nowMs, seed: seed,
                                                    signalSources: inputs.signalSources,
                                                    historySources: inputs.historySources)
        return MusicRecommendationEngine.selectKeyed(ranked, limit: limit, explorationFraction: exploration).map(\.pick)
    }
}

// MARK: - Home recommendations

/// A Home shelf or mix card (`HomeMusicSection`). `reasons` maps song id → why it was picked (negative reasons
/// excluded).
public struct HomeMusicSection: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var songs: [Song]
    public var reasons: [String: String]
    /// The reason keys in pick order (Android keeps a LinkedHashMap).
    public var reasonOrder: [String]

    public init(id: String, title: String, subtitle: String, songs: [Song], reasons: [(String, String)] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.songs = songs
        var map: [String: String] = [:]
        var order: [String] = []
        var seen = Set<KotlinKey>()
        for (k, v) in reasons {
            if seen.insert(KotlinKey(k)).inserted { order.append(k) }
            map[k] = v
        }
        self.reasons = map
        self.reasonOrder = order
    }
}

public struct HomeRecommendations: Sendable, Hashable {
    public var mixes: [HomeMusicSection]
    public var shelves: [HomeMusicSection]
}

/// Deterministic daily Home choices built from the same signals as Your Mix.
public enum HomeRecommendationPlanner {
    static let day: Int64 = 86_400_000
    static let minArtistRadioSongs = 3

    public static func plan(library: [Song], favorites: Set<String>,
                            signals: [String: MusicRecommendationEngine.Signal],
                            history: [String: MusicRecommendationEngine.History], discoveries: [Song] = [],
                            releases: [Song] = [], nowMs: Int64, seed: Int64, variant: MuselleVariant = .basic,
                            signalSources: [String: String] = [:], historySources: [String: String] = [:])
        -> HomeRecommendations
    {
        typealias Item = MusicRecommendationEngine.KeyedPick
        let key = MusicRecommendationEngine.recordingKey
        let rank = Muselle.rankKeyed(variant, songs: library + discoveries + releases, favorites: favorites,
                                     signals: signals, history: history, nowMs: nowMs, seed: seed,
                                     signalSources: signalSources, historySources: historySources)
        let localKeys = Set(library.map { KotlinKey(key($0)) })
        let local = rank.filter { localKeys.contains(KotlinKey($0.keys.recording)) }
        let favoriteKeys = Set(favorites.map(KotlinKey.init))
        var historyMap: [KotlinKey: MusicRecommendationEngine.History] = [:]
        for (k, v) in history { historyMap[KotlinKey(k)] = v }
        var signalMap: [KotlinKey: MusicRecommendationEngine.Signal] = [:]
        for (k, v) in signals { signalMap[KotlinKey(k)] = v }
        func isFavorite(_ song: Song) -> Bool {
            song.isFavorite || favoriteKeys.contains(KotlinKey(song.id))
                || favoriteKeys.contains(KotlinKey("spotify_\(song.spotifyId ?? "null")"))
        }
        func lastPlayed(_ song: Song) -> Int64 {
            max(historyMap[KotlinKey(song.id)]?.lastPlayedMs ?? 0, signalMap[KotlinKey(song.id)]?.lastPlayedMs ?? 0)
        }
        func section(_ id: String, _ title: String, _ subtitle: String, _ items: [Item], limit: Int = 24)
            -> (section: HomeMusicSection, keys: [KotlinKey])
        {
            let selected = MusicRecommendationEngine.selectKeyed(items, limit: limit)
            let reasons = selected.map(\.pick)
                .filter { !$0.reason.utf8.starts(with: MusicRecommendationEngine.reasonPrefixDemoted.utf8) }
                .map { ($0.song.id, $0.reason) }
            return (HomeMusicSection(id: id, title: title, subtitle: subtitle, songs: selected.map(\.pick.song),
                                     reasons: reasons),
                    selected.map { KotlinKey($0.keys.recording) })
        }

        var mixes: [(section: HomeMusicSection, keys: [KotlinKey])] = []
        let favoritesAndRepeats = local.filter { isFavorite($0.pick.song) || !$0.pick.unheard }
        if !favoritesAndRepeats.isEmpty {
            mixes.append(section("comfort", "Comfort zone", "Favorites and familiar voices", favoritesAndRepeats))
        }
        let unfamiliar = local.filter { $0.pick.unheard && !isFavorite($0.pick.song) }
        if !unfamiliar.isEmpty {
            mixes.append(section("fresh_ears", "Fresh ears", "Give an unplayed song a chance", unfamiliar))
        }
        var genreGroups = OrderedStringMap<[Item]>()
        for item in local {
            guard let genre = item.pick.song.genre, !genre.isKotlinBlank,
                  !KotlinText.equalsIgnoreCase(genre, "unknown") else { continue }
            let g = KotlinText.lowercase(genre).kotlinTrimmed()
            genreGroups.append(item, to: g)
        }
        let genres = genreGroups.entries.filter { $0.value.count >= 4 }.kotlinSorted { a, b in
            javaDoubleCompare(b.value.prefix(6).reduce(0.0) { $0 + $1.pick.score },
                              a.value.prefix(6).reduce(0.0) { $0 + $1.pick.score })
        }
        if let first = genres.first {
            let genre = first.value[0].pick.song.genre ?? "null"
            mixes.append(section("genre_\(genre)", "\(genre) mix", "A sound you keep coming back to", first.value))
        }
        let quick = local.filter { (1...(4 * 60_000)).contains($0.pick.song.duration) }
        if mixes.count < 3 && quick.count >= 3 {
            mixes.append(section("quick_listen", "Quick listens", "Short tracks for a small window of time", quick))
        }
        let long = local.filter { $0.pick.song.duration >= 7 * 60_000 }
        if mixes.count < 3 && long.count >= 3 {
            mixes.append(section("deep_listen", "Settle in", "Longer tracks for an uninterrupted session", long))
        }
        if mixes.count < 3 && local.count >= 4 {
            mixes.append(section("rotation", "Open rotation", "A little familiar, a little unexpected", local))
        }
        var seenMixes: [Set<KotlinKey>] = []
        let distinctMixes = mixes.filter { mix in
            let keys = Set(mix.keys)
            if seenMixes.contains(keys) { return false }
            seenMixes.append(keys)
            return true
        }.prefix(3).map(\.section)

        var used = Set<KotlinKey>()
        var shelves: [HomeMusicSection] = []
        func addShelf(_ id: String, _ title: String, _ subtitle: String, keys: Set<KotlinKey>, limit: Int = 12) {
            let items = rank.filter { let k = KotlinKey($0.keys.recording); return keys.contains(k) && !used.contains(k) }
            let next = section(id, title, subtitle, items, limit: limit)
            if !next.section.songs.isEmpty {
                shelves.append(next.section)
                used.formUnion(next.keys)
            }
        }
        func keys(_ items: [Item]) -> Set<KotlinKey> { Set(items.map { KotlinKey($0.keys.recording) }) }
        addShelf("recent_releases", "New from artists you enjoy", "Released in the past six months",
                 keys: Set(releases.map { KotlinKey(key($0)) }))
        addShelf("discovery", "Beyond your library", "New finds shaped by what you play",
                 keys: Set(discoveries.map { KotlinKey(key($0)) }).subtracting(localKeys))
        addShelf("recently_added", "Recently added", "New to your library", keys: keys(local.filter {
            let added = normalizeTimestampMs($0.pick.song.dateAdded)
            return added > 0 && nowMs &- added <= 30 * day
        }))
        addShelf("on_repeat", "On repeat", "The songs you keep coming back to", keys: keys(local.filter {
            let id = KotlinKey($0.pick.song.id)
            let repeats = (historyMap[id]?.plays ?? 0) + (signalMap[id]?.completions ?? 0)
            let last = lastPlayed($0.pick.song)
            return repeats >= 2 && last > 0 && nowMs &- last < 7 * day
        }))
        var artistGroups = OrderedStringMap<[Item]>()
        for item in local { artistGroups.append(item, to: item.keys.artist) }
        var favoriteArtist: (key: String, items: [Item], sum: Double)?
        for entry in artistGroups.entries where entry.value.count >= minArtistRadioSongs {
            let sum = entry.value.reduce(0.0) { $0 + $1.pick.score }
            if favoriteArtist == nil || javaDoubleCompare(favoriteArtist!.sum, sum) < 0 {
                favoriteArtist = (entry.key, entry.value, sum)
            }
        }
        if let artist = favoriteArtist {
            addShelf("artist_radio_\(artist.key)", "Artist radio", "A focused run around an artist you enjoy",
                     keys: keys(artist.items))
        }
        addShelf("favorites", "Always a good choice", "Your favorites, ready for another listen",
                 keys: keys(local.filter { isFavorite($0.pick.song) }))
        addShelf("rediscover", "Back in rotation", "Good songs you haven't played in a while", keys: keys(local.filter {
            let last = lastPlayed($0.pick.song)
            return last > 0 && nowMs &- last >= 7 * day
        }))
        addShelf("unplayed", "Waiting to be heard", "Fresh picks already in your library",
                 keys: keys(local.filter(\.pick.unheard)))
        addShelf("quick_listen", "Quick listens", "Short tracks when you only have a few minutes", keys: keys(quick))
        addShelf("deep_listen", "Settle in", "Longer tracks for an uninterrupted session", keys: keys(long))
        addShelf("more_for_you", "Keep exploring", "More picks from your collection", keys: keys(local))
        return HomeRecommendations(mixes: Array(distinctMixes), shelves: shelves)
    }

    /// `isRecentRelease`: only a complete `yyyy-MM-dd` date within the last 180 days and not in the future.
    public static func isRecentRelease(_ value: String?, today: LocalDate) -> Bool {
        guard let value, value.utf16.count == 10, let date = LocalDate.parseISO(value) else { return false }
        return date <= today && date >= today.plusDays(-180)
    }

    /// `dateAdded` arrives in seconds from some sources and milliseconds from others.
    static func normalizeTimestampMs(_ value: Int64) -> Int64 {
        if value <= 0 { return 0 }
        if value < 10_000_000_000 { return value &* 1_000 }
        return value
    }
}
