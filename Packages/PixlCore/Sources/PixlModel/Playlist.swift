// Playlists and smart-playlist rules, mirroring `data/model/PlayList.kt`, `SmartPlaylistRule.kt` and
// `data/premium/PremiumSmartTools.kt` (`SmartPlaylistPreset`). Codable keys match the kotlinx-serialized names;
// decoding fills Android's defaults for missing keys.

import Foundation
import PixlFoundation

/// Milliseconds since 1970 now (Kotlin `System.currentTimeMillis()`).
@inlinable
public func currentTimeMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

/// A user or generated playlist.
public struct Playlist: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var songIds: [String]
    public var createdAt: Int64
    public var lastModified: Int64
    public var isAiGenerated: Bool
    public var isQueueGenerated: Bool
    public var coverImageUri: String?
    /// ARGB colour (Kotlin Int).
    public var coverColorArgb: Int32?
    public var coverIconName: String?
    /// "Circle", "SmoothRect", "RotatedPill", "Star" (see `PlaylistShapeType`).
    public var coverShapeType: String?
    public var coverShapeDetail1: Float?
    public var coverShapeDetail2: Float?
    public var coverShapeDetail3: Float?
    public var coverShapeDetail4: Float?
    /// "LOCAL", "SPOTIFY", "AI", …
    public var source: String
    /// Manual drag position for `SortOption.playlistCustomOrder`.
    public var sortOrder: Int

    public init(id: String, name: String, songIds: [String], createdAt: Int64 = currentTimeMillis(),
                lastModified: Int64 = currentTimeMillis(), isAiGenerated: Bool = false, isQueueGenerated: Bool = false,
                coverImageUri: String? = nil, coverColorArgb: Int32? = nil, coverIconName: String? = nil,
                coverShapeType: String? = nil, coverShapeDetail1: Float? = nil, coverShapeDetail2: Float? = nil,
                coverShapeDetail3: Float? = nil, coverShapeDetail4: Float? = nil, source: String = "LOCAL",
                sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.songIds = songIds
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.isAiGenerated = isAiGenerated
        self.isQueueGenerated = isQueueGenerated
        self.coverImageUri = coverImageUri
        self.coverColorArgb = coverColorArgb
        self.coverIconName = coverIconName
        self.coverShapeType = coverShapeType
        self.coverShapeDetail1 = coverShapeDetail1
        self.coverShapeDetail2 = coverShapeDetail2
        self.coverShapeDetail3 = coverShapeDetail3
        self.coverShapeDetail4 = coverShapeDetail4
        self.source = source
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name, songIds, createdAt, lastModified, isAiGenerated, isQueueGenerated, coverImageUri,
             coverColorArgb, coverIconName, coverShapeType, coverShapeDetail1, coverShapeDetail2, coverShapeDetail3,
             coverShapeDetail4, source, sortOrder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        songIds = try c.decode([String].self, forKey: .songIds)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? currentTimeMillis()
        lastModified = try c.decodeIfPresent(Int64.self, forKey: .lastModified) ?? currentTimeMillis()
        isAiGenerated = try c.decodeIfPresent(Bool.self, forKey: .isAiGenerated) ?? false
        isQueueGenerated = try c.decodeIfPresent(Bool.self, forKey: .isQueueGenerated) ?? false
        coverImageUri = try c.decodeIfPresent(String.self, forKey: .coverImageUri)
        coverColorArgb = try c.decodeIfPresent(Int32.self, forKey: .coverColorArgb)
        coverIconName = try c.decodeIfPresent(String.self, forKey: .coverIconName)
        coverShapeType = try c.decodeIfPresent(String.self, forKey: .coverShapeType)
        coverShapeDetail1 = try c.decodeIfPresent(Float.self, forKey: .coverShapeDetail1)
        coverShapeDetail2 = try c.decodeIfPresent(Float.self, forKey: .coverShapeDetail2)
        coverShapeDetail3 = try c.decodeIfPresent(Float.self, forKey: .coverShapeDetail3)
        coverShapeDetail4 = try c.decodeIfPresent(Float.self, forKey: .coverShapeDetail4)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "LOCAL"
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

/// Playlist cover shapes (`PlaylistShapeType`).
public enum PlaylistShapeType: String, Sendable, Hashable, Codable, CaseIterable {
    case circle = "Circle"
    case smoothRect = "SmoothRect"
    case rotatedPill = "RotatedPill"
    case star = "Star"
}

/// Rule-based playlists offered at creation time (`SmartPlaylistRule`). `storageKey` is persisted.
public enum SmartPlaylistRule: String, Sendable, Hashable, Codable, CaseIterable {
    case topPlayed = "top_played"
    case recentlyPlayed = "recently_played"
    case forgottenFavorites = "forgotten_favorites"
    case newGems = "new_gems"

    public var storageKey: String { rawValue }

    /// Kotlin enum constant name.
    public var kotlinName: String {
        switch self {
        case .topPlayed: "TOP_PLAYED"
        case .recentlyPlayed: "RECENTLY_PLAYED"
        case .forgottenFavorites: "FORGOTTEN_FAVORITES"
        case .newGems: "NEW_GEMS"
        }
    }

    /// English title (localised in the app's String Catalog).
    public var title: String {
        switch self {
        case .topPlayed: "Top Played"
        case .recentlyPlayed: "Recently Played"
        case .forgottenFavorites: "Forgotten Favorites"
        case .newGems: "New Gems"
        }
    }

    public var subtitle: String {
        switch self {
        case .topPlayed: "Your most played tracks."
        case .recentlyPlayed: "Songs you listened to most recently."
        case .forgottenFavorites: "Favorite tracks you haven't played in a while."
        case .newGems: "Recently added tracks with low play counts."
        }
    }

    /// `fromStorageKey`: nil for nil, blank or unknown keys.
    public static func fromStorageKey(_ key: String?) -> SmartPlaylistRule? {
        guard let key, !key.isKotlinBlank else { return nil }
        return allCases.first { $0.storageKey.isIdentical(to: key) }
    }
}

/// Local smart-playlist presets (`SmartPlaylistPreset`); raw value = Kotlin constant name.
public enum SmartPlaylistPreset: String, Sendable, Hashable, Codable, CaseIterable {
    case favorites = "FAVORITES"
    case discover = "DISCOVER"
    case recentlyAdded = "RECENTLY_ADDED"
    case shortListen = "SHORT_LISTEN"
    case longListen = "LONG_LISTEN"
    case artistRadio = "ARTIST_RADIO"

    public var displayName: String {
        switch self {
        case .favorites: "Favorites, refreshed"
        case .discover: "Deep discovery"
        case .recentlyAdded: "Recently added"
        case .shortListen: "Short listens"
        case .longListen: "Long-form listening"
        case .artistRadio: "Artist radio"
        }
    }

    /// The explanation shown with a generated playlist.
    public var explanation: String {
        switch self {
        case .favorites: "Your favorites, balanced with the tracks you return to most."
        case .discover: "A wider, artist-diverse mix with room for songs you have not played."
        case .recentlyAdded: "The newest music in your library, in arrival order."
        case .shortListen: "Quick tracks for a focused listening session."
        case .longListen: "Longer tracks for an uninterrupted listening session."
        case .artistRadio: "A local radio-style mix shaped by your listening history."
        }
    }
}
