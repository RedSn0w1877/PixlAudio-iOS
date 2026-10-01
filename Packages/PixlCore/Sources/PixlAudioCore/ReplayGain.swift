// ReplayGain, ported from data/media/ReplayGainManager.kt (tag parsing and gain → volume) and
// data/service/ReplayGainProcessor.kt (the volume bookkeeping around track changes and crossfades).
// Tag reading itself is the app's job (AVFoundation metadata / PixlTags); it hands the tag map in here.

import Foundation
import PixlFoundation

/// ReplayGain values read from one file's tags.
public struct ReplayGainValues: Sendable, Hashable, Codable {
    public var trackGainDb: Float?
    public var albumGainDb: Float?

    public init(trackGainDb: Float? = nil, albumGainDb: Float? = nil) {
        self.trackGainDb = trackGainDb
        self.albumGainDb = albumGainDb
    }
}

/// `ReplayGainManager` without the file I/O and the LRU cache (the app caches by file).
public enum ReplayGain {
    /// Track-gain tag keys in priority order (TagLib's upper-case property-map keys).
    public static let trackGainKeys = ["REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_GAIN_DB", "R128_TRACK_GAIN"]
    /// Album-gain tag keys in priority order.
    public static let albumGainKeys = ["REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_GAIN_DB", "R128_ALBUM_GAIN"]
    /// Pre-amp applied with the gain (`DEFAULT_PRE_AMP_DB`).
    public static let defaultPreAmpDb: Float = 0
    /// Highest volume multiplier (`coerceIn(0f, 2f)`, +6 dB). Player volumes are capped at 1 on Android, so in
    /// practice boosts above unity are only audible where the caller allows them (`ReplayGainStage`).
    public static let maxVolume: Float = 2
    /// Size of Android's per-file cache (`removeEldestEntry` above 200 entries), for the app's own cache.
    public static let cacheCapacity = 200

    /// Reads track and album gain from a tag map (keys compared upper-cased, like TagLib's property map; the first
    /// value of a key counts). Returns nil when neither is present.
    public static func values(fromTags tags: [String: [String]]) -> ReplayGainValues? {
        var upper: [String: [String]] = [:]
        // A key already in upper case wins over spellings that only differ in case (deterministic).
        for (key, value) in tags {
            let normalized = key.uppercased()
            if normalized == key || upper[normalized] == nil { upper[normalized] = value }
        }
        let track = extractGainValue(upper, keys: trackGainKeys)
        let album = extractGainValue(upper, keys: albumGainKeys)
        if track == nil && album == nil { return nil }
        return ReplayGainValues(trackGainDb: track, albumGainDb: album)
    }

    /// `extractGainValue`: the first key that has a value decides — its parse result is returned even when it fails
    /// (later keys are not tried), exactly like Android.
    ///
    /// Deviation: `R128_*` values are Opus Q7.8 integers relative to −23 LUFS; Android parses them as decibels (so a
    /// typical "-1536" became −1536 dB, i.e. silence). Here they are converted to ReplayGain decibels
    /// (`value / 256 + 5`).
    public static func extractGainValue(_ map: [String: [String]], keys: [String]) -> Float? {
        for key in keys {
            guard let raw = map[key]?.first else { continue }
            if key.hasPrefix("R128_") { return parseR128Gain(raw) }
            return parseGainString(raw)
        }
        return nil
    }

    /// `parseGainString`: trims, removes every "dB" (any case), trims again and parses with Kotlin's
    /// `toFloatOrNull` grammar ("-6.54 dB" → −6.54; "1e3", "0x1p3", "NaN", "Infinity", "1.5f" are accepted too).
    public static func parseGainString(_ raw: String) -> Float? {
        let trimmed = KotlinText.trim(raw)
        var scalars = String.UnicodeScalarView()
        var it = trimmed.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = it.next()
        while let c = pending {
            let next = it.next()
            if (c == "d" || c == "D"), let n = next, n == "b" || n == "B" {
                pending = it.next()
                continue
            }
            scalars.append(c)
            pending = next
        }
        return KotlinText.toFloatOrNull(KotlinText.trim(String(scalars)))
    }

    /// An Opus R128 gain (signed Q7.8 integer, −23 LUFS reference) as ReplayGain decibels (−18 LUFS reference).
    public static func parseR128Gain(_ raw: String) -> Float? {
        let text = KotlinText.trim(raw)
        guard let value = Int(text), value >= Int(Int16.min), value <= Int(Int16.max) else { return nil }
        return Float(value) / 256 + 5
    }

    /// `gainDbToVolume`: `10^((gain + preAmp) / 20)` clamped to 0…2 (Kotlin `Float.pow` evaluates in Double).
    @inlinable
    public static func gainDbToVolume(_ gainDb: Float, preAmpDb: Float = defaultPreAmpDb) -> Float {
        let total = gainDb + preAmpDb
        let linear = Float(Foundation.pow(10.0, Double(total / 20)))
        return linear.coerced(in: 0, maxVolume)
    }

    /// `getVolumeMultiplier`: track gain (or album gain when `useAlbumGain`), falling back to the other one, then
    /// to 1 (no change).
    @inlinable
    public static func volumeMultiplier(_ values: ReplayGainValues?, useAlbumGain: Bool = false,
                                        preAmpDb: Float = defaultPreAmpDb) -> Float {
        guard let values else { return 1 }
        let gain = useAlbumGain ? (values.albumGainDb ?? values.trackGainDb) : (values.trackGainDb ?? values.albumGainDb)
        guard let gain else { return 1 }
        return gainDbToVolume(gain, preAmpDb: preAmpDb)
    }
}

/// The bookkeeping of `ReplayGainProcessor` as a value type. The app keeps one instance on its playback actor,
/// performs the tag read itself (`beginApply` → read → `completeApply`) and applies the returned volumes to the
/// active deck. Android's `player.volume` clamps to 0…1; so do the volumes returned here.
public struct ReplayGainVolumeController: Sendable, Hashable {
    public var enabled: Bool = false
    public var useAlbumGain: Bool = false
    /// The volume the user last chose by hand; restored whenever ReplayGain is off.
    public private(set) var userSelectedVolume: Float = 1
    /// The volume just written programmatically (to ignore its echo in `onPlayerVolumeChanged`).
    public private(set) var expectedVolume: Float?
    /// A ReplayGain volume computed mid-crossfade, applied when the transition finishes.
    public private(set) var pendingVolume: Float?
    /// The last applied ReplayGain volume (re-applied at once on track changes, avoiding a full-volume spike).
    public private(set) var lastAppliedVolume: Float?
    /// The media id `lastAppliedVolume` belongs to.
    public private(set) var lastMediaId: String?
    /// Incremented by every `beginApply`; results carrying an older token are stale.
    public private(set) var requestToken: Int64 = 0
    /// What the crossfade should ramp the incoming deck to (`DualPlayerEngine.incomingTrackReplayGainVolume`).
    public var incomingTrackVolume: Float?

    public init(enabled: Bool = false, useAlbumGain: Bool = false) {
        self.enabled = enabled
        self.useAlbumGain = useAlbumGain
    }

    /// Seeds the user volume from the player at startup (`captureUserVolume`).
    public mutating func captureUserVolume(_ volume: Float) { userSelectedVolume = volume.coerced(in: 0, 1) }

    /// Records a programmatic volume change and returns the clamped value to write to the player (`setPlayerVolume`).
    public mutating func setPlayerVolume(_ volume: Float) -> Float {
        let clamped = volume.coerced(in: 0, 1)
        expectedVolume = clamped
        return clamped
    }

    /// The player reported a volume change: our own echo is ignored, anything else is the user's choice.
    public mutating func onPlayerVolumeChanged(_ volume: Float, transitionRunning: Bool) {
        if transitionRunning { return }
        if let expected = expectedVolume, abs(expected - volume) < 0.001 {
            expectedVolume = nil
            return
        }
        expectedVolume = nil
        userSelectedVolume = volume.coerced(in: 0, 1)
    }

    /// Re-applies the last ReplayGain volume without reading tags (resume, same-track seeks, queue edits).
    public mutating func reapplyLastAppliedVolume(transitionRunning: Bool) -> Float? {
        if transitionRunning { return nil }
        guard let last = lastAppliedVolume else { return nil }
        return setPlayerVolume(last)
    }

    /// The start of `apply(mediaItem)`.
    public struct ApplyRequest: Sendable, Hashable {
        /// Pass back to `completeApply`.
        public var token: Int64
        /// Volume to write now (user volume when off / no file; last ReplayGain volume while reading), or nil.
        public var immediateVolume: Float?
        /// True when the app must read the tags and call `completeApply`.
        public var needsTagRead: Bool
        /// The album-gain choice captured at request time.
        public var useAlbumGain: Bool
    }

    /// `apply(mediaItem)` up to the tag read. `hasFilePath` is false for items without a local file (streams).
    public mutating func beginApply(mediaId: String?, hasFilePath: Bool, transitionRunning: Bool) -> ApplyRequest {
        requestToken += 1
        let token = requestToken
        guard mediaId != nil else {
            return ApplyRequest(token: token, immediateVolume: nil, needsTagRead: false, useAlbumGain: useAlbumGain)
        }
        if !enabled {
            pendingVolume = nil
            let volume = transitionRunning ? nil : setPlayerVolume(userSelectedVolume)
            return ApplyRequest(token: token, immediateVolume: volume, needsTagRead: false, useAlbumGain: useAlbumGain)
        }
        if !hasFilePath {
            let volume = transitionRunning ? nil : setPlayerVolume(userSelectedVolume)
            return ApplyRequest(token: token, immediateVolume: volume, needsTagRead: false, useAlbumGain: useAlbumGain)
        }
        var immediate: Float?
        if !transitionRunning, let last = lastAppliedVolume { immediate = setPlayerVolume(last) }
        return ApplyRequest(token: token, immediateVolume: immediate, needsTagRead: true, useAlbumGain: useAlbumGain)
    }

    /// The end of `apply(mediaItem)` once the tags were read. Returns the volume to write to the active deck, or nil
    /// (stale result, or a crossfade is running — then the volume is kept pending and handed to the fade).
    public mutating func completeApply(_ request: ApplyRequest, mediaId: String, currentMediaId: String?,
                                       values: ReplayGainValues?, transitionRunning: Bool) -> Float? {
        guard request.token == requestToken, currentMediaId == mediaId else { return nil }
        let volume = ReplayGain.volumeMultiplier(values, useAlbumGain: request.useAlbumGain)
        if transitionRunning {
            pendingVolume = volume
            incomingTrackVolume = volume
            return nil
        }
        pendingVolume = nil
        incomingTrackVolume = nil
        lastAppliedVolume = volume
        lastMediaId = mediaId
        return setPlayerVolume(volume)
    }

    /// `prepareForTransition`: seeds the incoming volume from already-cached tags (no I/O) so the fade ends at the
    /// right level. The app then calls `beginApply` for the incoming item.
    public mutating func prepareForTransition(cachedValues: ReplayGainValues?) {
        guard enabled, let cachedValues else { return }
        incomingTrackVolume = ReplayGain.volumeMultiplier(cachedValues, useAlbumGain: useAlbumGain)
    }

    /// The engine cancelled or finished a fade (`incomingTrackReplayGainVolume = null`).
    public mutating func clearIncomingTrackVolume() { incomingTrackVolume = nil }

    /// What to do when a crossfade finishes.
    public enum TransitionFinish: Sendable, Hashable {
        /// Write this volume to the (new) active deck.
        case setVolume(Float)
        /// No pending volume: run `beginApply` for the current item.
        case recompute
    }

    /// `onTransitionFinished`.
    public mutating func onTransitionFinished() -> TransitionFinish {
        let pending = pendingVolume
        pendingVolume = nil
        if !enabled { return .setVolume(setPlayerVolume(userSelectedVolume)) }
        if let pending {
            lastAppliedVolume = pending
            return .setVolume(setPlayerVolume(pending))
        }
        return .recompute
    }

    /// What to do when the current item's metadata changed.
    public enum MetadataChange: Sendable, Hashable {
        /// The track changed: run `beginApply`.
        case recompute
        /// Same track (queue edit): write this volume (nil: nothing to re-apply).
        case reapply(Float?)
        /// No current item.
        case ignore
    }

    /// `onMediaMetadataChanged`: recompute only when the track actually changed.
    public mutating func onMediaMetadataChanged(currentMediaId: String?, transitionRunning: Bool) -> MetadataChange {
        guard let currentMediaId else { return .ignore }
        if currentMediaId != lastMediaId { return .recompute }
        return .reapply(reapplyLastAppliedVolume(transitionRunning: transitionRunning))
    }
}

/// The ReplayGain stage of the processing tap: a smoothed gain followed by an optional soft limiter. Android caps the
/// player volume at 1, so `allowBoost` defaults to false (parity); with it, gains above 1 (up to +6 dB) pass through
/// `SoftLimiter` so they never clip.
public struct ReplayGainStage: Sendable, Hashable {
    public var allowBoost: Bool
    /// Limiter knee (linear). Default −1 dBFS.
    public var limiterThreshold: Float
    /// The gain applied at the end of the previous buffer (ramps from here to the new target, no zipper noise).
    public private(set) var currentGain: Float

    public init(allowBoost: Bool = false, limiterThreshold: Float = SoftLimiter.defaultThreshold, initialGain: Float = 1) {
        self.allowBoost = allowBoost
        self.limiterThreshold = limiterThreshold
        currentGain = initialGain
    }

    /// The gain actually applied for a ReplayGain volume.
    @inlinable
    public func effectiveGain(for volume: Float) -> Float {
        let v = volume.isNaN ? 1 : volume
        return allowBoost ? v.coerced(in: 0, ReplayGain.maxVolume) : v.coerced(in: 0, 1)
    }

    /// Applies the gain (ramping from the previous buffer's gain) and, when boosting, the limiter. In place, no
    /// allocation.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, volume: Float) {
        let target = effectiveGain(for: volume)
        GainRamp.apply(to: samples, frames: frames, channels: channels, from: currentGain, to: target)
        currentGain = target
        if allowBoost && target > limiterThreshold {
            SoftLimiter.process(samples, count: frames * channels, threshold: limiterThreshold)
        }
    }
}

/// A memoryless soft-knee limiter: identity below `threshold`, then a tanh curve towards ±1 (never beyond).
/// Allocation-free.
public enum SoftLimiter {
    /// −1 dBFS.
    public static let defaultThreshold: Float = 0.891_250_9

    /// The limited value of one sample.
    @inlinable
    public static func limit(_ x: Float, threshold: Float = defaultThreshold) -> Float {
        if x.isNaN { return 0 }
        let t = threshold.isNaN ? defaultThreshold : threshold.coerced(in: 0, 1)
        if t >= 1 { return x.coerced(in: -1, 1) }
        let a = abs(x)
        if a <= t { return x }
        let headroom = 1 - t
        let y = t + headroom * Float(tanh(Double((a - t) / headroom)))
        return x < 0 ? -y : y
    }

    /// Limits `count` samples in place.
    @inlinable
    public static func process(_ samples: UnsafeMutablePointer<Float>, count: Int, threshold: Float = defaultThreshold) {
        for i in 0..<count { samples[i] = limit(samples[i], threshold: threshold) }
    }
}
