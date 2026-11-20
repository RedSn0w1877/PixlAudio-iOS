// What the optional batch jobs ("Let Taizo help the engine", docs/brain-spec.md, 9.4) brought back, cached forever by (model id, prompt version,
// input hash) in one small file. A port of Android's `AssistCache`. The jobs themselves are `AssistantHelp`; this holds their validated answers
// and gives them to the three places that may use them, each only while the switch is on:
//  - an island's name on Your sound (an answer is used only when the island's genres are still the ones it was written for);
//  - a song's genres, as tag source 10 (the assembler reads them, the tag merge treats them as the weakest source);
//  - suggested songs by artists the listener likely does not know, which an assistant mix may draw from (arm ASK).
//
// An answer that did not validate is stored as "asked, nothing usable", so the same input is never asked twice. Nothing in the file is ever
// shown or used unless it passed `AssistBatch`; with the switch off the file is not read.

import Foundation
import PixlModel

public actor AssistCache {
    public static let fileName = "assist_cache.json"

    public struct IslandAnswer: Codable, Sendable, Equatable {
        public var name: String
        public var line: String
        public init(name: String = "", line: String = "") {
            self.name = name
            self.line = line
        }
    }

    public struct TagAnswer: Codable, Sendable, Equatable {
        public var atlasId: Int
        public var conf: Int
        public init(atlasId: Int, conf: Int) {
            self.atlasId = atlasId
            self.conf = conf
        }
    }

    public struct AskAnswer: Codable, Sendable, Equatable {
        public var videoId: String
        public var title: String
        public var artist: String
        public var album: String
        public var year: Int
        public var durationSec: Int
        public var artUrl: String
        public var rid: Int64
        public init(videoId: String, title: String, artist: String, album: String = "", year: Int = 0, durationSec: Int = 0,
                    artUrl: String = "", rid: Int64 = 0) {
            self.videoId = videoId
            self.title = title
            self.artist = artist
            self.album = album
            self.year = year
            self.durationSec = durationSec
            self.artUrl = artUrl
            self.rid = rid
        }
    }

    public struct Contents: Codable, Sendable, Equatable {
        /// Island answers by `AssistBatch.cacheKey` of the island's own input (hex).
        public var islands: [String: IslandAnswer] = [:]
        /// Tag answers by the key of the track's input (hex); an empty list is "asked, nothing usable".
        public var tags: [String: [TagAnswer]] = [:]
        /// Suggested songs by the key of the week's input (hex).
        public var ask: [String: [AskAnswer]] = [:]
        /// The newest ask key: what an assistant mix draws from.
        public var askLatest = ""
        /// The recordings whose genres the tagging job wrote, so turning the switch off can take them back out.
        public var tagRids: [Int64] = []

        public init() {}
    }

    private let file: URL?
    private let modelId: String
    private let allowed: @Sendable () async -> Bool
    private var cached: Contents?

    /// `modelId` is part of every key, so a model change asks again. `allowed` is the switch (local and remote): asked before an answer is read.
    public init(file: URL?, modelId: String, allowed: @escaping @Sendable () async -> Bool) {
        self.file = file
        self.modelId = modelId
        self.allowed = allowed
    }

    public func read() -> Contents {
        if let cached { return cached }
        var loaded = Contents()
        if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Contents.self, from: data) { loaded = decoded }
        cached = loaded
        return loaded
    }

    /// Applies `change` to the contents and saves them. A small file and rare writes (the refresh's own runs).
    public func update(_ change: (inout Contents) -> Void) {
        var next = read()
        change(&next)
        cached = next
        if let file, let data = try? JSONEncoder().encode(next) { try? data.write(to: file, options: [.atomic]) }
    }

    // MARK: Keys

    public func keyOf(_ kind: String, _ input: String) -> String {
        String(UInt64(bitPattern: AssistBatch.cacheKey(modelId: modelId, kind: kind, input: input)), radix: 16)
    }

    /// The input an island's name is cached under: its stable id and the names of its genres (never its artists, which drift).
    public static func islandInput(id: Int, genreNames: [String]) -> String { "\(id)|" + genreNames.joined(separator: "|") }

    // MARK: Uses

    /// The assistant-written name of an island whose own genres are `genreNames`, or nil: the switch is off, nothing validated, or it was
    /// written for other genres.
    public func islandName(id: Int, genreNames: [String]) async -> String? {
        if genreNames.isEmpty { return nil }
        guard await allowed() else { return nil }
        let name = read().islands[keyOf("island", Self.islandInput(id: id, genreNames: genreNames))]?.name ?? ""
        return BrainText.isBlank(name) ? nil : name
    }

    /// The tag claims the assistant gave a track whose input was `input`, or empty. Not gated: the assembler gates by the switch itself.
    public func tagsFor(_ input: String) -> [TagAnswer] { read().tags[keyOf("tag", input)] ?? [] }

    /// The songs the assistant suggested this week, as rows a pool can draw from (arm ASK), when the switch is on.
    public func suggestedRows() async -> [StoredRadioRow] {
        guard await allowed() else { return [] }
        let d = read()
        return (d.ask[d.askLatest] ?? []).filter { $0.rid != 0 && !BrainText.isBlank($0.videoId) }.map { a in
            StoredRadioRow(
                row: RadioRow(videoId: a.videoId, title: a.title, artists: [RadioArtistRef(name: a.artist)],
                              album: a.album.isEmpty ? nil : a.album, year: a.year, durationSec: a.durationSec,
                              thumbnailUrl: a.artUrl.isEmpty ? nil : a.artUrl, kind: .atv),
                rid: a.rid)
        }
    }
}
