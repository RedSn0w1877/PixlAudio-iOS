// A rendition is another version of a song's audio made by the cloud: a spatial render in one profile, or the
// Enhanced (restored) stereo song (cloud audio spec of 2026-11-10, sections 3, 6.1 and 6.2). These are the names the
// library, the local store, the job manifest and the two app services share.

import Foundation

/// What a rendition is.
public enum RenditionKind: Sendable, Hashable {
    /// The binaural render of one profile.
    case spatial(SpatialProfile)
    /// The restored stereo song.
    case enhanced

    /// Every kind: the six spatial ones in profile order, then Enhanced.
    public static let allKinds: [RenditionKind] = SpatialProfile.allCases.map(RenditionKind.spatial) + [.enhanced]

    /// The slot name: the file stem in the library and in the local store (`sp-studio`, `enhanced`), and the name of
    /// this output in a job manifest's `outputs` and `library.renders`.
    public var slot: String {
        switch self {
        case .spatial(let profile): "sp-\(profile.rawValue)"
        case .enhanced: "enhanced"
        }
    }

    /// The kind a slot names, or nil for anything else.
    public init?(slot: String) {
        if slot == "enhanced" {
            self = .enhanced
        } else if slot.hasPrefix("sp-"), let profile = SpatialProfile(rawValue: String(slot.dropFirst(3))) {
            self = .spatial(profile)
        } else {
            return nil
        }
    }

    /// A render manifest's `kind`: `spatial` or `enhanced`.
    public var manifestKind: String {
        switch self {
        case .spatial: "spatial"
        case .enhanced: "enhanced"
        }
    }

    public var profile: SpatialProfile? {
        if case .spatial(let profile) = self { return profile }
        return nil
    }

    public var isSpatial: Bool { profile != nil }
}

/// One rendition of one song. The song is named by the YouTube video it plays from (`videoId`), never by its Spotify
/// id: a render belongs to that audio, and every device that plays the same video shares it. The library version is
/// not part of the key: it is `CloudLibrary.version` everywhere, and a render of another version is not a hit.
public struct RenditionKey: Sendable, Hashable, CustomStringConvertible {
    public var videoId: String
    public var kind: RenditionKind

    public init(videoId: String, kind: RenditionKind) {
        self.videoId = videoId
        self.kind = kind
    }

    public init(videoId: String, profile: SpatialProfile) {
        self.init(videoId: videoId, kind: .spatial(profile))
    }

    public var description: String { "\(videoId)/\(kind.slot)" }
}

/// Where a song's rendition stands on this phone (spec 6.1): `none` → `preview` (the on-device stage) → `queued` →
/// `processing` → `ready` (a verified local render), or `failed` (tried again later, see `RenditionRetry`).
public enum RenditionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// Nothing is known or wanted.
    case none
    /// The on-device stage stands in; no cloud work is under way (yet, or at all).
    case preview
    /// Wanted from the cloud: waiting for the library check, the upload or a GPU.
    case queued
    /// The cloud is rendering it, or the finished render is coming down.
    case processing
    /// A verified render is in the local store.
    case ready
    /// The last try failed; it is tried again after a pause.
    case failed

    /// The cloud is on its way to a render.
    public var isInFlight: Bool { self == .queued || self == .processing }

    /// What the person is told for the playing song: the library's own status when the cloud is doing or has done
    /// something, else `preview` while the on-device stage is what plays.
    public static func shown(library: RenditionStatus, onDeviceAudible: Bool) -> RenditionStatus {
        switch library {
        case .queued, .processing, .ready, .failed: library
        case .none, .preview: onDeviceAudible ? .preview : .none
        }
    }
}

/// When a failed rendition is tried again (spec 6.1): 10 minutes after the first failure, an hour after the second,
/// a day after every later one.
public enum RenditionRetry {
    public static let backoffMs: [Int64] = [600_000, 3_600_000, 86_400_000]

    /// The pause after `failures` failures in a row (0 = none yet, so no pause).
    public static func delayMs(afterFailures failures: Int) -> Int64 {
        guard failures > 0 else { return 0 }
        return backoffMs[min(failures, backoffMs.count) - 1]
    }

    /// Whether a rendition that failed `failures` times, last at `lastFailureAtMs`, may be tried again at `nowMs`.
    public static func isDue(failures: Int, lastFailureAtMs: Int64, nowMs: Int64) -> Bool {
        nowMs - lastFailureAtMs >= delayMs(afterFailures: failures)
    }
}
