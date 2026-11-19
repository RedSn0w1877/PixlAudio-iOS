// A genre page's facts (docs/brain-spec.md, 8.7): only what the atlas holds. The description exists for the roughly 200
// genres the atlas describes by hand; for the others the page shows facts alone, and nothing is written at run time. A
// fact the atlas does not have is absent, never guessed. A transliteration of the Android `:brain` module's `GenrePage.kt`.

/// The facts of a genre page.
public enum GenrePage {
    public struct Page: Sendable {
        public let id: Int
        public let name: String
        /// The atlas's own paragraph; nil for a genre it does not describe.
        public let description: String?
        /// "Seoul · 1990s": the first regions and the decade the genre began; nil when the atlas has neither.
        public let origin: String?
        /// "Comes from".
        public let parents: [Int]
        /// "Branches": the genres that list this one as a parent.
        public let children: [Int]
        /// "Close to".
        public let related: [Int]
        /// "Shaped by": the genres it was influenced by, and the ones it fuses.
        public let influences: [Int]
    }

    /// The page of `id`, or nil when the atlas has no such genre.
    public static func of(_ atlas: GenreAtlas, _ id: Int) -> Page? {
        guard let g = atlas.genre(id) else { return nil }
        var children: [Int] = []
        for other in atlas.allIds {
            guard let o = atlas.genre(other) else { continue }
            if o.parents.contains(id) { children.append(other) }
        }
        var influences: [Int] = []
        var seen: Set<Int> = []
        for i in g.influencedBy.sorted() where seen.insert(i).inserted { influences.append(i) }
        for i in g.fusionOf.sorted() where seen.insert(i).inserted { influences.append(i) }
        let regions = g.regions.filter { !BrainText.isBlank($0) }.prefix(2).joined(separator: ", ")
        let era = (1000...2999).contains(g.eraStart) ? "\((g.eraStart / 10) * 10)s" : ""
        let origin = [regions, era].filter { !$0.isEmpty }.joined(separator: " · ")
        return Page(id: id, name: g.name, description: BrainText.isBlank(g.description) ? nil : g.description,
                    origin: origin.isEmpty ? nil : origin, parents: g.parents.sorted(), children: children,
                    related: g.related.sorted(), influences: influences)
    }
}
