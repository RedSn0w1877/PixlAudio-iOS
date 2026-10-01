// Smart playlists: the rule-based playlists offered at creation (`PlaylistViewModel.buildSmartPlaylistSongIds`)
// and the local presets with the listening-insights summary (`data/premium/PremiumSmartTools.kt`).

import Foundation
import PixlFoundation
import PixlModel

public enum SmartPlaylistBuilder {
    /// `SMART_PLAYLIST_MAX_ITEMS`.
    public static let maxItems = 100
    static let staleAfterMs: Int64 = 30 * 86_400_000

    /// The song ids a `SmartPlaylistRule` playlist starts with. `engagements` is the engagement table in storage
    /// order (ties keep it); when a rule picks nothing the newest songs are used.
    public static func songIds(for rule: SmartPlaylistRule, allSongs: [Song],
                               engagements: [(songId: String, stats: EngagementStats)], favoriteIds: Set<String>,
                               nowMs: Int64, limit: Int = maxItems) -> [String] {
        if allSongs.isEmpty { return [] }
        var songById: [KotlinKey: Song] = [:]
        for song in allSongs { songById[KotlinKey(song.id)] = song }
        var engagementById: [KotlinKey: EngagementStats] = [:]
        for entry in engagements { engagementById[KotlinKey(entry.songId)] = entry.stats }
        let favorites = Set(favoriteIds.map(KotlinKey.init))
        let safeLimit = min(max(limit, 1), allSongs.count)
        let picked: [Song]
        switch rule {
        case .topPlayed:
            picked = Array(engagements.kotlinSorted { a, b in
                chain(cmp(b.stats.playCount, a.stats.playCount), cmp(b.stats.totalPlayDurationMs, a.stats.totalPlayDurationMs),
                      cmp(b.stats.lastPlayedTimestamp, a.stats.lastPlayedTimestamp))
            }.compactMap { songById[KotlinKey($0.songId)] }.prefix(safeLimit))
        case .recentlyPlayed:
            picked = Array(engagements.filter { $0.stats.lastPlayedTimestamp > 0 }
                .kotlinSorted { cmp($1.stats.lastPlayedTimestamp, $0.stats.lastPlayedTimestamp) }
                .compactMap { songById[KotlinKey($0.songId)] }.prefix(safeLimit))
        case .forgottenFavorites:
            let threshold = nowMs &- staleAfterMs
            let last: (Song) -> Int64 = { engagementById[KotlinKey($0.id)]?.lastPlayedTimestamp ?? 0 }
            picked = Array(allSongs.filter { favorites.contains(KotlinKey($0.id)) }
                .kotlinSorted { chain(cmp(last($0), last($1)), KotlinText.compare(KotlinText.lowercase($0.title), KotlinText.lowercase($1.title))) }
                .filter { last($0) < threshold }.prefix(safeLimit))
        case .newGems:
            let plays: (Song) -> Int = { engagementById[KotlinKey($0.id)]?.playCount ?? 0 }
            picked = Array(allSongs.kotlinSorted { chain(cmp($1.dateAdded, $0.dateAdded), cmp(plays($0), plays($1))) }
                .filter { plays($0) <= 2 }.prefix(safeLimit))
        }
        if !picked.isEmpty { return picked.map(\.id).kotlinDistinct() }
        return allSongs.kotlinSorted { cmp($1.dateAdded, $0.dateAdded) }.prefix(safeLimit).map(\.id)
    }
}

/// A generated preset playlist.
public struct SmartPlaylistResult: Sendable, Hashable {
    public var preset: SmartPlaylistPreset
    public var songs: [Song]
    public var explanation: String
}

/// Deterministic, explainable local playlists (`PremiumSmartPlaylistEngine`).
public enum PremiumSmartPlaylistEngine {
    public static func build(_ preset: SmartPlaylistPreset, songs: [Song], favorites: Set<String> = [],
                             history: [String: MusicRecommendationEngine.History] = [:],
                             signals: [String: MusicRecommendationEngine.Signal] = [:], nowMs: Int64 = currentTimeMillis(),
                             seed: Int64? = nil, limit: Int = 30) -> SmartPlaylistResult {
        let clean = songs.filter { !$0.title.isKotlinBlank }.kotlinDistinct(by: MusicRecommendationEngine.recordingKey)
        if limit <= 0 || clean.isEmpty { return SmartPlaylistResult(preset: preset, songs: [], explanation: preset.explanation) }
        let favoriteKeys = Set(favorites.map(KotlinKey.init))
        var historyMap: [KotlinKey: MusicRecommendationEngine.History] = [:]
        for (k, v) in history { historyMap[KotlinKey(k)] = v }
        let selected: [Song]
        switch preset {
        case .favorites:
            let plays: (Song) -> Int = { historyMap[KotlinKey($0.id)]?.plays ?? 0 }
            selected = clean.filter { $0.isFavorite || favoriteKeys.contains(KotlinKey($0.id)) }
                .kotlinSorted { chain(cmp(plays($1), plays($0)), KotlinText.compare($0.title, $1.title)) }
        case .recentlyAdded:
            selected = clean.kotlinSorted {
                chain(cmp($1.dateAdded, $0.dateAdded), cmp($1.dateModified, $0.dateModified), KotlinText.compare($0.title, $1.title))
            }
        case .shortListen:
            selected = clean.kotlinSorted { cmp($0.duration > 0 ? $0.duration : Int64.max, $1.duration > 0 ? $1.duration : Int64.max) }
        case .longListen:
            selected = clean.kotlinSorted { cmp($1.duration, $0.duration) }
        case .artistRadio, .discover:
            let ranked = Muselle2.rankKeyed(songs: clean, favorites: favorites, signals: signals, history: history,
                                       nowMs: nowMs, seed: seed ?? nowMs, signalSources: [:], historySources: [:])
            selected = MusicRecommendationEngine.selectKeyed(ranked, limit: limit,
                                                        explorationFraction: preset == .discover ? 0.5 : 0.2).map(\.pick.song)
        }
        return SmartPlaylistResult(preset: preset, songs: Array(selected.prefix(limit)), explanation: preset.explanation)
    }
}

/// A compact local listening summary (`ListeningInsights`).
public struct ListeningInsights: Sendable, Hashable {
    public var songCount: Int
    public var playedSongCount: Int
    public var totalListeningMs: Int64
    public var completionRatePercent: Int
    public var topArtists: [(name: String, plays: Int)]
    public var topGenres: [(name: String, count: Int)]
    public var discoveryRatePercent: Int

    /// `totalListeningLabel()`: "Xh Ym" from an hour, else "Ym".
    public var totalListeningLabel: String {
        let minutes = max(totalListeningMs / 60_000, 0)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    public static func == (lhs: ListeningInsights, rhs: ListeningInsights) -> Bool {
        lhs.songCount == rhs.songCount && lhs.playedSongCount == rhs.playedSongCount
            && lhs.totalListeningMs == rhs.totalListeningMs && lhs.completionRatePercent == rhs.completionRatePercent
            && lhs.topArtists.elementsEqual(rhs.topArtists, by: { $0.name == $1.name && $0.plays == $1.plays })
            && lhs.topGenres.elementsEqual(rhs.topGenres, by: { $0.name == $1.name && $0.count == $1.count })
            && lhs.discoveryRatePercent == rhs.discoveryRatePercent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(songCount)
        hasher.combine(playedSongCount)
        hasher.combine(totalListeningMs)
    }
}

/// `PremiumInsightEngine.summarize`.
public enum PremiumInsightEngine {
    public static func summarize(_ songs: [Song], history: [String: MusicRecommendationEngine.History] = [:],
                                 signals: [String: MusicRecommendationEngine.Signal] = [:]) -> ListeningInsights {
        var historyMap: [KotlinKey: MusicRecommendationEngine.History] = [:]
        for (k, v) in history { historyMap[KotlinKey(k)] = v }
        var signalMap: [KotlinKey: MusicRecommendationEngine.Signal] = [:]
        for (k, v) in signals { signalMap[KotlinKey(k)] = v }
        let plays: (Song) -> Int = { historyMap[KotlinKey($0.id)]?.plays ?? 0 }
        let sessionsOf: (Song) -> Int = { signalMap[KotlinKey($0.id)]?.sessions ?? 0 }
        let unique = songs.filter { !$0.title.isKotlinBlank }.kotlinDistinct(by: MusicRecommendationEngine.recordingKey)
        let played = unique.filter { plays($0) > 0 || sessionsOf($0) > 0 }
        let totalMs = max(unique.reduce(Int64(0)) {
            $0 &+ max(historyMap[KotlinKey($1.id)]?.listenedMs ?? 0, signalMap[KotlinKey($1.id)]?.listenedMs ?? 0)
        }, 0)
        let sessions = max(unique.reduce(0) { $0 + sessionsOf($1) }, 0)
        let completions = max(unique.reduce(0) { $0 + (signalMap[KotlinKey($1.id)]?.completions ?? 0) }, 0)
        let unheard = unique.filter { plays($0) == 0 && sessionsOf($0) == 0 }.count
        var artistGroups = OrderedStringMap<Int>()
        for song in unique {
            let name = song.displayArtist.isKotlinBlank ? "Unknown artist" : song.displayArtist
            artistGroups[name] = (artistGroups[name] ?? 0) + max(plays(song), sessionsOf(song))
        }
        let artists = artistGroups.entries.filter { $0.value > 0 }.kotlinSorted { cmp($1.value, $0.value) }
            .prefix(5).map { (name: $0.key, plays: $0.value) }
        var genreGroups = OrderedStringMap<Int>()
        for song in unique {
            guard let genre = song.genre?.kotlinTrimmed(), !genre.isKotlinBlank else { continue }
            genreGroups[genre] = (genreGroups[genre] ?? 0) + 1
        }
        let genres = genreGroups.entries.kotlinSorted { cmp($1.value, $0.value) }.prefix(5).map { (name: $0.key, count: $0.value) }
        let completionRate = sessions == 0 ? 0
            : Int(KotlinMath.roundToLong(Double(completions) / Double(sessions) * 100)).coerced(in: 0, 100)
        let discoveryRate = unique.isEmpty ? 0
            : Int(KotlinMath.roundToLong((Double(unheard) / Double(unique.count)) * 100)).coerced(in: 0, 100)
        return ListeningInsights(songCount: unique.count, playedSongCount: played.count, totalListeningMs: totalMs,
                                 completionRatePercent: completionRate, topArtists: Array(artists),
                                 topGenres: Array(genres), discoveryRatePercent: discoveryRate)
    }
}
