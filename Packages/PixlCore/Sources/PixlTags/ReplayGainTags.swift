// ReplayGain tag handling, ported from Android's `ReplayGainManager` (reading + volume multiplier),
// `AudioMetadataReader.extractReplayGainDb` and the ReplayGain parts of `SongMetadataEditor`.

import Foundation
import PixlFoundation
import PixlModel

// `ReplayGainValues` (Android `ReplayGainManager.ReplayGainValues`) lives in PixlModel, shared with PixlAudioCore.

/// How an edit changes one ReplayGain field (Android's private `ReplayGainUpdate`).
public enum ReplayGainUpdate: Sendable, Hashable {
    /// Leave the tag as it is (the field was not edited).
    case keep
    /// Remove the tag (the field was cleared).
    case clear
    /// Write the value, already formatted as `"%.2f dB"`.
    case set(String)
}

public enum ReplayGainTags {
    /// Keys looked up for the track gain, in order (`TRACK_GAIN_KEYS`). `R128_TRACK_GAIN` is parsed as dB like the
    /// others, as Android does.
    public static let trackGainKeys = ["REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_GAIN_DB", "R128_TRACK_GAIN"]
    /// Keys looked up for the album gain (`ALBUM_GAIN_KEYS`).
    public static let albumGainKeys = ["REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_GAIN_DB", "R128_ALBUM_GAIN"]
    /// The keys the editor writes.
    public static let trackGainKey = "REPLAYGAIN_TRACK_GAIN"
    public static let albumGainKey = "REPLAYGAIN_ALBUM_GAIN"
    /// The MP4 reverse-DNS issuer used for ReplayGain free-form atoms.
    public static let mp4ReverseDnsIssuer = "com.apple.iTunes"
    /// `DEFAULT_PRE_AMP_DB`.
    public static let defaultPreAmpDb: Float = 0

    /// `replayGainMp4FieldId(key)`: `----:com.apple.iTunes:<key>`.
    public static func mp4FieldId(_ key: String) -> String { "----:\(mp4ReverseDnsIssuer):\(key)" }

    // MARK: Parsing

    /// `ReplayGainManager.parseGainString`: trim, drop every `dB`, trim, `toFloatOrNull`. No comma handling.
    public static func parseGainString(_ raw: String) -> Float? {
        KotlinText.toFloatOrNull(KotlinText.removingDb(raw.kotlinTrimmed()).kotlinTrimmed())
    }

    /// `AudioMetadataReader.parseReplayGainDb`: like `parseGainString` but a decimal comma is accepted.
    public static func parseReplayGainDb(_ raw: String?) -> Float? {
        guard let raw else { return nil }
        let cleaned = KotlinText.removingDb(KotlinText.replacingCommas(raw.kotlinTrimmed())).kotlinTrimmed()
        return KotlinText.toFloatOrNull(cleaned)
    }

    /// `ReplayGainManager.extractGainValue`: the first key that has a value decides (even when it does not parse).
    public static func extractGainValue(_ properties: TagProperties, keys: [String]) -> Float? {
        for key in keys {
            guard let raw = properties[key]?.first else { continue }
            return parseGainString(raw)
        }
        return nil
    }

    /// `AudioMetadataReader.extractReplayGainDb`: the first key whose value parses.
    public static func extractReplayGainDb(_ properties: TagProperties, keys: [String]) -> Float? {
        for key in keys {
            guard let raw = properties[key]?.first else { continue }
            if let value = parseReplayGainDb(raw) { return value }
        }
        return nil
    }

    /// `ReplayGainManager.readReplayGain` after the tag read: nil when neither gain is present.
    public static func values(from properties: TagProperties) -> ReplayGainValues? {
        let track = extractGainValue(properties, keys: trackGainKeys)
        let album = extractGainValue(properties, keys: albumGainKeys)
        if track == nil && album == nil { return nil }
        return ReplayGainValues(trackGainDb: track, albumGainDb: album)
    }

    // MARK: Volume

    /// `ReplayGainManager.gainDbToVolume`: `10^((gain + preAmp) / 20)` clamped to 0…2 (+6 dB at most).
    public static func gainDbToVolume(_ gainDb: Float, preAmpDb: Float = defaultPreAmpDb) -> Float {
        let total = gainDb + preAmpDb
        let linear = Float(Foundation.pow(10.0, Double(total / 20)))
        return linear.coerced(in: 0, 2)
    }

    /// `ReplayGainManager.getVolumeMultiplier`: track gain (or album gain when `useAlbumGain`) with the other as
    /// fallback; 1 when there is nothing to apply.
    public static func volumeMultiplier(_ values: ReplayGainValues?, useAlbumGain: Bool = false,
                                        preAmpDb: Float = defaultPreAmpDb) -> Float {
        guard let values else { return 1 }
        let gain = useAlbumGain ? (values.albumGainDb ?? values.trackGainDb) : (values.trackGainDb ?? values.albumGainDb)
        guard let gain else { return 1 }
        return gainDbToVolume(gain, preAmpDb: preAmpDb)
    }

    // MARK: Editing

    /// `SongMetadataEditor.parseReplayGainUpdate`: nil → keep, blank → clear, otherwise a dB value (decimal comma
    /// and a trailing `dB` allowed) formatted as `"%.2f dB"`; anything else is an error naming `fieldName`.
    public static func parseUpdate(_ raw: String?, fieldName: String) -> Result<ReplayGainUpdate, MetadataEditFailure> {
        guard let raw else { return .success(.keep) }
        let trimmed = raw.kotlinTrimmed()
        if trimmed.isEmpty { return .success(.clear) }
        let normalized = KotlinText.removingTrailingDbUnit(KotlinText.replacingCommas(trimmed)).kotlinTrimmed()
        guard let gain = KotlinText.toFloatOrNull(normalized) else {
            return .failure(MetadataEditFailure(.invalidInput, "\(fieldName) must be a valid dB value"))
        }
        return .success(.set(KotlinText.formatFixed2(gain) + " dB"))
    }

    /// `MutableMap.applyReplayGainUpdate` (the TagLib property-map path).
    public static func apply(_ update: ReplayGainUpdate, key: String, to properties: inout TagProperties) {
        switch update {
        case .keep: break
        case .clear: properties.remove(key)
        case .set(let value): properties[key] = [value]
        }
    }
}
