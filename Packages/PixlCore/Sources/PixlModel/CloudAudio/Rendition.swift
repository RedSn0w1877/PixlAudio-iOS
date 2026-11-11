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

/// Where a song's rendition stands on this phone (spec 6.1): `none` → `preview` (the on-device stage) → `queued` →
/// `processing` → `downloading` → `ready` (a verified local render), or `failed` (tried again later, see
/// `RenditionRetry`).
public enum RenditionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// Nothing is known or wanted.
    case none
    /// The on-device stage stands in; no cloud work is under way (yet, or at all).
    case preview
    /// Wanted from the cloud: waiting for the library check, the upload or a GPU, or unable to start yet
    /// (`RenditionQueueReason`).
    case queued
    /// The song is uploaded and the cloud is rendering it.
    case processing
    /// A finished render (this job's, or one the shared library already had) is coming down and being verified.
    case downloading
    /// A verified render is in the local store.
    case ready
    /// The last try failed; it is tried again after a pause.
    case failed

    /// The cloud is on its way to a render.
    public var isInFlight: Bool { self == .queued || self == .processing || self == .downloading }
}

/// Why a render that is wanted cannot start yet (spec 6.1: `queued` with a reason).
public enum RenditionQueueReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// No network the person allows for cloud work.
    case waitingForNetwork
    /// The month's limit for library jobs is reached.
    case capReached
}

/// A rendition's status, with the reason when it is queued and cannot start.
public struct RenditionState: Sendable, Hashable {
    public var status: RenditionStatus
    /// Only ever set together with `queued`.
    public var queueReason: RenditionQueueReason?

    /// A reason given with any status but `queued` is dropped.
    public init(_ status: RenditionStatus, queueReason: RenditionQueueReason? = nil) {
        self.status = status
        self.queueReason = status == .queued ? queueReason : nil
    }

    public static let none = RenditionState(.none)
    public static let ready = RenditionState(.ready)

    /// What the person is told for the playing song: the library's own state once the cloud is doing or has done
    /// something, else `preview` while the on-device stage is what plays.
    public func shown(onDeviceAudible: Bool) -> RenditionState {
        switch status {
        case .queued, .processing, .downloading, .ready, .failed: self
        case .none, .preview: RenditionState(onDeviceAudible ? .preview : .none)
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
