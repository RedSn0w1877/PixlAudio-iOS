import Foundation
import PixlLibrary
import Synchronization

/// Album-art colour schemes, the iOS counterpart of Android's `ColorSchemeProcessor`: decode the artwork at
/// 128 px (`ArtworkPipeline`), pick the seed with PixlLibrary's port of `selectSeedColorArgbFromPixels`, build the
/// light + dark schemes (`ArtworkTheme.schemePair`), cache them in memory (256 entries, like Android's LRU) and in
/// `ArtworkThemeRecord` (Android `album_art_themes`), keyed by `<artwork key>|<style>|accuracy_<n>|algo_v7`.
actor ColorExtractor {
    private let pipeline: ArtworkPipeline
    private let persistence: PersistenceActor?
    private var memory: [String: ColorRolesPair] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<ColorRolesPair?, Never>] = [:]
    private static let memoryLimit = 256
    /// A synchronous mirror of the memory cache (larger, LRU), so a view can start with its album colours on the
    /// first frame instead of the brand theme followed by a 0.25 s re-theme (Android `peekCachedColorScheme`).
    nonisolated let mirror = SchemeMemory(limit: 1024)

    init(pipeline: ArtworkPipeline, persistence: PersistenceActor?) {
        self.pipeline = pipeline
        self.persistence = persistence
    }

    /// The scheme pair for `source`, generating it when no cache has it. Nil when the artwork can't be decoded.
    func schemePair(for source: ArtworkSource, style: ArtworkPaletteStyle = .default,
                    accuracyLevel: Int = ArtworkColorAccuracy.default) async -> ColorRolesPair? {
        let paletteKey = ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracyLevel)
        let key = source.cacheKey + "|" + paletteKey
        if let hit = memory[key] { return hit }
        if let task = inFlight[key] { return await task.value }
        let pipeline = self.pipeline
        let persistence = self.persistence
        let artworkKey = source.cacheKey
        let task = Task.detached(priority: .userInitiated) { () -> ColorRolesPair? in
            if let stored = try? await persistence?.artworkTheme(key: key) { return stored }
            guard let pixels = await pipeline.argbPixels(source, maxDimension: ArtworkTheme.extractionMaxDimension),
                  !pixels.isEmpty else { return nil }
            let seed = ArtworkTheme.seedColor(argbPixels: pixels, accuracyLevel: accuracyLevel)
            let pair = ArtworkTheme.schemePair(seed: seed, style: style)
            try? await persistence?.saveArtworkTheme(key: key, artworkKey: artworkKey, paletteKey: paletteKey, pair: pair)
            return pair
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { remember(result, for: key) }
        return result
    }

    /// A memory-cache hit without generating (Android `peekCachedColorScheme`, memory part).
    func cachedPair(for source: ArtworkSource, style: ArtworkPaletteStyle, accuracyLevel: Int) -> ColorRolesPair? {
        memory[source.cacheKey + "|" + ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracyLevel)]
    }

    /// The cached scheme pair, read synchronously from any thread (a view's `body`): what `schemePair` would return
    /// at once from memory. Nil means "not in memory" — call `schemePair`.
    nonisolated func peek(_ source: ArtworkSource, style: ArtworkPaletteStyle, accuracyLevel: Int) -> ColorRolesPair? {
        mirror.value(for: source.cacheKey + "|" + ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracyLevel))
    }

    /// Drops every cached scheme of an artwork (Android `invalidateScheme`).
    func invalidate(_ source: ArtworkSource) async {
        let prefix = source.cacheKey + "|"
        for key in memory.keys where key.hasPrefix(prefix) { memory[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
        mirror.removeAll(withPrefix: prefix)
        try? await persistence?.deleteArtworkThemes(artworkKey: source.cacheKey)
    }

    private func remember(_ pair: ColorRolesPair, for key: String) {
        mirror.insert(pair, for: key)
        if memory.updateValue(pair, forKey: key) == nil { order.append(key) }
        if order.count > Self.memoryLimit {
            let overflow = order.count - Self.memoryLimit
            for old in order.prefix(overflow) { memory[old] = nil }
            order.removeFirst(overflow)
        }
    }
}

/// The scheme cache's synchronous mirror: an LRU guarded by a `Mutex` (like `ArtworkPipeline.MemoryCache`), read by
/// views in `body`. Recency is a counter per entry, so a hit costs one lookup; eviction scans only on overflow.
nonisolated final class SchemeMemory: Sendable {
    private struct State {
        var entries: [String: (pair: ColorRolesPair, tick: UInt64)] = [:]
        var tick: UInt64 = 0
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(for key: String) -> ColorRolesPair? {
        state.withLock { s in
            guard let hit = s.entries[key] else { return nil }
            s.tick &+= 1
            s.entries[key] = (hit.pair, s.tick)
            return hit.pair
        }
    }

    func insert(_ pair: ColorRolesPair, for key: String) {
        state.withLock { s in
            s.tick &+= 1
            s.entries[key] = (pair, s.tick)
            guard s.entries.count > limit else { return }
            // Drop the least recently used eighth at once, so overflow scans stay rare.
            let drop = max(1, limit / 8)
            let oldest = s.entries.sorted { $0.value.tick < $1.value.tick }.prefix(drop).map(\.key)
            for old in oldest { s.entries[old] = nil }
        }
    }

    func removeAll(withPrefix prefix: String) {
        state.withLock { s in
            for key in s.entries.keys where key.hasPrefix(prefix) { s.entries[key] = nil }
        }
    }
}
