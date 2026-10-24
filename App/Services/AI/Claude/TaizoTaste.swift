import Foundation
import PixlLibrary
import PixlModel
import Synchronization

/// What Ask Taizo's taste tools and its listening context read: the taste profile (`TasteProfileBuilder`), the plays per
/// library song, and the library's search index. All of it is built off the main thread, once, and kept until something
/// it depends on changes (a finished song, an import, a library change, a taste change), so asking twice costs nothing.
@MainActor
enum TaizoTaste {
    static let cache = TaizoDataCache()

    /// The stores the profile reads, loaded (each reads its file off the main thread, once).
    static func prepare(_ env: AppEnvironment) async {
        await env.home.history.ensureLoaded()
        await env.importedHistory.ensureLoaded()
        await env.musicTaste.ensureLoaded()
        await env.tasteAdjustments.ensureLoaded()
    }

    /// Plays and the last play per library song (the app's and the imported ones that name a library song).
    static func playStats(_ env: AppEnvironment) async -> [String: SongPlayStats] {
        let stamp = TaizoDataCache.Stamp(library: env.library.songsRevision, songCount: env.library.songs.count,
                                         history: env.home.history.revision, imported: env.importedHistory.revision,
                                         taste: 0, adjustments: 0)
        if let hit = cache.stats(stamp: stamp) { return hit }
        let sources = await env.importedHistory.tasteSources()
        let stats = await Task.detached(priority: .userInitiated) { SongPlayStats.build(plays: sources.plays) }.value
        cache.setStats(stats, stamp: stamp)
        return stats
    }

    /// The profile for a period; `period` falls back to all time inside the builder when it holds no plays.
    static func profile(_ env: AppEnvironment, period: ListeningPeriod) async -> TasteProfile {
        await prepare(env)
        let stamp = TaizoDataCache.Stamp(library: env.library.songsRevision, songCount: env.library.songs.count,
                                         history: env.home.history.revision, imported: env.importedHistory.revision,
                                         taste: env.musicTaste.revision, adjustments: env.tasteAdjustments.revision)
        if let hit = cache.profile(period.toolValue, stamp: stamp) { return hit }
        let sources = await env.importedHistory.tasteSources()
        let songs = env.library.songs
        let signals = env.musicTaste.learnedSignals
        let adjustments = env.tasteAdjustments.items
        let clock = env.home.history.clock
        let now = clock.nowMs(), zone = clock.timeZone
        let profile = await Task.detached(priority: .userInitiated) { () -> TasteProfile in
            let inputs = TasteProfileInputs(songs: songs, plays: sources.plays, importedPlays: sources.imported, taste: sources.taste,
                                            localSignals: signals, adjustments: adjustments, nowMs: now, timeZone: zone)
            return TasteProfileBuilder.build(inputs, period: period)
        }.value
        cache.setProfile(profile, key: period.toolValue, stamp: stamp)
        return profile
    }
}

/// The cached results, behind a lock (they are read and written from the main actor, but the cache itself is plain data).
nonisolated final class TaizoDataCache: Sendable {
    /// What a cached result depends on.
    struct Stamp: Sendable, Equatable {
        var library: Int
        var songCount: Int
        var history: Int
        var imported: Int
        var taste: Int
        var adjustments: Int
    }

    private struct State: Sendable {
        var indexRevision: Int?
        var index: SearchIndex?
        var statsStamp: Stamp?
        var stats: [String: SongPlayStats] = [:]
        var profileStamp: Stamp?
        var profiles: [String: TasteProfile] = [:]
    }

    private let state = Mutex(State())

    func index(revision: Int) -> SearchIndex? {
        state.withLock { $0.indexRevision == revision ? $0.index : nil }
    }

    func setIndex(_ index: SearchIndex, revision: Int) {
        state.withLock {
            $0.indexRevision = revision
            $0.index = index
        }
    }

    func stats(stamp: Stamp) -> [String: SongPlayStats]? {
        state.withLock { $0.statsStamp == stamp ? $0.stats : nil }
    }

    func setStats(_ stats: [String: SongPlayStats], stamp: Stamp) {
        state.withLock {
            $0.statsStamp = stamp
            $0.stats = stats
        }
    }

    func profile(_ key: String, stamp: Stamp) -> TasteProfile? {
        state.withLock { $0.profileStamp == stamp ? $0.profiles[key] : nil }
    }

    func setProfile(_ profile: TasteProfile, key: String, stamp: Stamp) {
        state.withLock {
            if $0.profileStamp != stamp {
                $0.profileStamp = stamp
                $0.profiles = [:]
            }
            $0.profiles[key] = profile
        }
    }
}
