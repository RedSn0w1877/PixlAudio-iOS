// Crossfade/transition settings mirroring `data/model/Transition.kt`. Enum raw values are the Kotlin constant
// names (that is what Room and the backup store).

import Foundation

/// How one song hands over to the next.
public enum TransitionMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// No transition: the next song starts after the previous one ends (gapless).
    case none = "NONE"
    /// The current song fades out completely before the next fades in.
    case fadeInOut = "FADE_IN_OUT"
    /// The current song fades out while the next fades in, overlapping.
    case overlap = "OVERLAP"
    /// Overlap with S-shaped fades.
    case smooth = "SMOOTH"
}

/// Shape of a fade's volume curve.
public enum TransitionCurve: String, Sendable, Hashable, Codable, CaseIterable {
    case linear = "LINEAR"
    /// Exponential: fast start, slow end.
    case exp = "EXP"
    /// Logarithmic: slow start, fast end.
    case log = "LOG"
    /// Sigmoid.
    case sCurve = "S_CURVE"
}

/// Where resolved transition settings came from (playlist rules override the global default).
public enum TransitionSource: String, Sendable, Hashable, Codable, CaseIterable {
    case globalDefault = "GLOBAL_DEFAULT"
    case playlistDefault = "PLAYLIST_DEFAULT"
    case playlistSpecific = "PLAYLIST_SPECIFIC"
}

/// Settings for one transition.
public struct TransitionSettings: Sendable, Hashable, Codable {
    public var mode: TransitionMode
    /// Overlap/fade length in ms (Kotlin Int).
    public var durationMs: Int
    public var curveIn: TransitionCurve
    public var curveOut: TransitionCurve

    /// Android defaults: overlap, 2000 ms, S-curves both ways.
    public init(mode: TransitionMode = .overlap, durationMs: Int = 2000, curveIn: TransitionCurve = .sCurve,
                curveOut: TransitionCurve = .sCurve) {
        self.mode = mode
        self.durationMs = durationMs
        self.curveIn = curveIn
        self.curveOut = curveOut
    }

    enum CodingKeys: String, CodingKey { case mode, durationMs, curveIn, curveOut }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TransitionMode.self, forKey: .mode) ?? .overlap
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 2000
        curveIn = try c.decodeIfPresent(TransitionCurve.self, forKey: .curveIn) ?? .sCurve
        curveOut = try c.decodeIfPresent(TransitionCurve.self, forKey: .curveOut) ?? .sCurve
    }
}

/// Settings plus the source they were resolved from.
public struct TransitionResolution: Sendable, Hashable, Codable {
    public var settings: TransitionSettings
    public var source: TransitionSource

    public init(settings: TransitionSettings, source: TransitionSource) {
        self.settings = settings
        self.source = source
    }
}

/// A transition rule for a playlist; with both track ids nil it is the playlist's default rule.
public struct TransitionRule: Sendable, Hashable, Codable, Identifiable {
    public var id: Int64
    public var playlistId: String
    public var fromTrackId: String?
    public var toTrackId: String?
    public var settings: TransitionSettings

    public init(id: Int64 = 0, playlistId: String, fromTrackId: String? = nil, toTrackId: String? = nil,
                settings: TransitionSettings) {
        self.id = id
        self.playlistId = playlistId
        self.fromTrackId = fromTrackId
        self.toTrackId = toTrackId
        self.settings = settings
    }

    /// True for the playlist-wide default (no track pair).
    public var isPlaylistDefault: Bool { fromTrackId == nil && toTrackId == nil }
}
