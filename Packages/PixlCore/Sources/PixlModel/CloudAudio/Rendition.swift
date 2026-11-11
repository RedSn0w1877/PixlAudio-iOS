// A rendition is the cloud's spatial render of one song in one profile (cloud audio spec of 2026-11-10, sections 3,
// 6.1 and 6.2). These are the names the library, the local store, the job manifest and the two app services share.

import Foundation

/// One rendition: a song's render in one profile. The song is named by the YouTube video it plays from (`videoId`),
/// never by its Spotify id: a render belongs to that audio, and every device that plays the same video shares it.
/// The library version is not part of the key: it is `CloudLibrary.version` everywhere, and a render of another
/// version is not a hit.
public struct RenditionKey: Sendable, Hashable, CustomStringConvertible {
    /// A render manifest's `kind`. Always `spatial` (the field stays so other kinds can be added without a new schema).
    public static let manifestKind = "spatial"

    public var videoId: String
    public var profile: SpatialProfile

    public init(videoId: String, profile: SpatialProfile) {
        self.videoId = videoId
        self.profile = profile
    }

    /// The slot name `sp-<profile>`: the file stem in the library and in the local store, and the name of this output
    /// in a job manifest's `outputs`.
    public var slot: String { Self.slot(profile) }

    public static func slot(_ profile: SpatialProfile) -> String { "sp-\(profile.rawValue)" }

    /// The profile a slot names, or nil for anything else.
    public static func profile(slot: String) -> SpatialProfile? {
        guard slot.hasPrefix("sp-") else { return nil }
        return SpatialProfile(rawValue: String(slot.dropFirst(3)))
    }

    public var description: String { "\(videoId)/\(slot)" }
}

/// Where one song stands for one profile (spec 6.1: "Per song and profile the app tracks: `none` → `preview`
/// (on-device) → `queued` → `processing` → `downloading` → `ready` … or `failed`"), keyed by `RenditionKey`; the order
/// of the cases is the usual way forward. The Android app's `SpatialRenditionStatus` has the same nine cases in the
/// same order.
///
/// The spec's `queued` is three cases here, because "a render that is wanted but cannot start yet is `queued` with a
/// reason" (6.1) and each reason has its own status line (6.5): `queued` with no reason, `waitingForNetwork` and
/// `capReached`. `isQueued` is true for all three.
///
/// `SpatialLibrary` keeps and reports the cloud's side of it: every case but `preview`, which is the player's fact and
/// is added by `shown(onDeviceAudible:)`.
public enum RenditionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// Nothing is known, wanted or under way for this song and profile.
    case none
    /// The on-device stage stands in and no cloud work is under way, yet or at all (6.1 "preview (on-device)"). Never
    /// reported by the library: see `shown(onDeviceAudible:)`.
    case preview
    /// Wanted from the cloud and not on a GPU yet: the shared-library check, preparing and uploading the song, or
    /// waiting for a worker (6.2 steps 2-3).
    case queued
    /// `queued` with the reason `waitingForNetwork` (6.1): wanted, but there is no network the person allows for cloud
    /// work. It starts by itself when one comes back.
    case waitingForNetwork
    /// `queued` with the reason `capReached` (6.1): wanted, but the month's limit for library jobs
    /// (`cloudAudio.monthlyCapUSD`) is reached.
    case capReached
    /// The GPU is working on it (6.2 step 3).
    case processing
    /// The render exists, in the shared library or as the result of the job, and is coming down to be verified (6.2
    /// steps 2 and 4). A state of its own on both platforms (6.1), with its own line.
    case downloading
    /// A verified render is in the local store (6.2 "Local store"): every later play starts on it (6.3).
    case ready
    /// The last attempt failed. It is tried again later with backoff (`RenditionRetry`: 10 minutes, 1 hour, 1 day).
    case failed

    /// The spec's `queued` (6.1), with or without a reason: `queued`, `waitingForNetwork` or `capReached`.
    public var isQueued: Bool { self == .queued || self == .waitingForNetwork || self == .capReached }

    /// What the person is told for the playing song (6.1), `self` being the library's answer: that answer when the cloud
    /// is doing or has done something, else `preview` while the on-device stage is what plays, else `none`.
    public func shown(onDeviceAudible: Bool) -> RenditionStatus {
        switch self {
        case .none, .preview: onDeviceAudible ? .preview : .none
        case .queued, .waitingForNetwork, .capReached, .processing, .downloading, .ready, .failed: self
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
