import Foundation
import PixlLibrary

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

    /// Drops every cached scheme of an artwork (Android `invalidateScheme`).
    func invalidate(_ source: ArtworkSource) async {
        let prefix = source.cacheKey + "|"
        for key in memory.keys where key.hasPrefix(prefix) { memory[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
        try? await persistence?.deleteArtworkThemes(artworkKey: source.cacheKey)
    }

    private func remember(_ pair: ColorRolesPair, for key: String) {
        if memory.updateValue(pair, forKey: key) == nil { order.append(key) }
        if order.count > Self.memoryLimit {
            let overflow = order.count - Self.memoryLimit
            for old in order.prefix(overflow) { memory[old] = nil }
            order.removeFirst(overflow)
        }
    }
}
