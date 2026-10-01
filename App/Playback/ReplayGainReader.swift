import Foundation
import PixlAudioCore
import PixlModel
import PixlTags

/// Reads ReplayGain values from a local file's tags, off the main thread, with Android's 200-entry cache.
///
/// Duplication decision (stage 5): PixlTags and PixlAudioCore both port Android's ReplayGain tag parsing. Playback uses
/// **PixlAudioCore's `ReplayGain.values(fromTags:)` fed with PixlTags' property map** (`AudioTagReader.read(_:)
/// .properties.dictionary`): PixlTags owns reading every container (ID3v2/ID3v1, FLAC Vorbis comments, MP4 free-form
/// atoms), PixlAudioCore owns the gain maths, including the R128 Q7.8 conversion that PixlTags' copy (an exact Android
/// port that reads R128 as dB) lacks. PixlTags' `ReplayGainTags.values(from:)` stays for the tag editor's parity.
actor ReplayGainReader {
    private var cache: [String: ReplayGainValues?] = [:]
    private var order: [String] = []

    /// The values for the file at `url` (nil when it has none or can't be read).
    func values(for url: URL) -> ReplayGainValues? {
        let key = url.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        let values = Self.read(url)
        cache[key] = values
        order.append(key)
        if order.count > ReplayGain.cacheCapacity {
            cache[order.removeFirst()] = nil
        }
        return values
    }

    func clear() {
        cache = [:]
        order = []
    }

    /// Reads the tags (memory-mapped, so large FLACs cost no copy) and hands the map to PixlAudioCore.
    nonisolated static func read(_ url: URL) -> ReplayGainValues? {
        guard url.isFileURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let tags = try? AudioTagReader.read(data) else { return nil }
        return ReplayGain.values(fromTags: tags.properties.dictionary)
    }
}
