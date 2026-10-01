// `pickBestAudio` from `YouTubeStreamResolver.kt`, and the iOS selection on top of it: AVPlayer cannot play Opus in
// WebM, so on iOS only AAC (`mp4a`, itags 141/140/139) is eligible, with the muxed itag 18 (H.264 + AAC) last.

import Foundation

/// Audio format choice.
public enum AudioFormatSelection {
    /// AAC itags in preference order at equal bitrate: 256 kbps, 128 kbps, 48 kbps HE-AAC.
    public static let aacItags: [Int] = [141, 140, 139]

    /// Android `pickBestAudio(maxBitrateKbps)`: highest real bitrate wins (141 AAC 256 > 251 Opus ~160 > 140 AAC
    /// 128); itag 18 always last; Opus preferred at equal bitrate. The user's cap only trims among what is
    /// offered — if it would leave nothing, it is ignored rather than returning silence.
    public static func pickBestAudio(_ formats: [YouTubeAudioFormat], maxBitrateKbps: Int? = nil) -> YouTubeAudioFormat? {
        if formats.isEmpty { return nil }
        let realAudio = formats.filter { !$0.isMuxedFallback }
        let audioFirst = realAudio.isEmpty ? formats : realAudio
        let capped = maxBitrateKbps.map { cap in audioFirst.filter { $0.bitrate <= cap &* 1000 } } ?? audioFirst
        let candidates = capped.isEmpty ? audioFirst : capped
        func key(_ f: YouTubeAudioFormat) -> (Int, Int, Int) {
            (f.isMuxedFallback ? 0 : 1, f.bitrate, (f.mimeType.map { NetText.containsIgnoreCase($0, "opus") } ?? false) ? 1 : 0)
        }
        // Kotlin maxWithOrNull keeps the first of equal maxima.
        var best = candidates[0]
        for f in candidates.dropFirst() where key(f) > key(best) { best = f }
        return best
    }

    /// Whether AVPlayer can play this format progressively: AAC in MP4 (`audio/mp4; codecs="mp4a…"`, or a known
    /// AAC itag without a MIME type), or the muxed itag 18 fallback.
    public static func isPlayableOnIOS(_ format: YouTubeAudioFormat) -> Bool {
        if format.isMuxedFallback { return true }
        guard let mime = format.mimeType else { return aacItags.contains(format.itag) }
        let lower = mime.lowercased()
        return lower.hasPrefix("audio/mp4") && (lower.contains("mp4a") || !lower.contains("codecs"))
    }

    /// The iOS pick: only AAC-in-MP4 formats (then itag 18), ranked like `pickBestAudio` (bitrate, cap), with the
    /// AAC itag order 141 → 140 → 139 breaking ties.
    public static func pickBestIOSAudio(_ formats: [YouTubeAudioFormat], maxBitrateKbps: Int? = nil) -> YouTubeAudioFormat? {
        let eligible = formats.filter(isPlayableOnIOS)
        if eligible.isEmpty { return nil }
        let realAudio = eligible.filter { !$0.isMuxedFallback }
        let audioFirst = realAudio.isEmpty ? eligible : realAudio
        let capped = maxBitrateKbps.map { cap in audioFirst.filter { $0.bitrate <= cap &* 1000 } } ?? audioFirst
        let candidates = capped.isEmpty ? audioFirst : capped
        func key(_ f: YouTubeAudioFormat) -> (Int, Int, Int) {
            let rank = aacItags.firstIndex(of: f.itag).map { aacItags.count - $0 } ?? 0
            return (f.isMuxedFallback ? 0 : 1, f.bitrate, rank)
        }
        var best = candidates[0]
        for f in candidates.dropFirst() where key(f) > key(best) { best = f }
        return best
    }

    /// The formats a resolver may use: when the client requires a streaming PoToken and none was issued, only the
    /// PoToken-exempt muxed fallback.
    public static func eligibleFormats(_ response: YouTubePlayerResponse, profile: InnerTubeClientProfile) -> [YouTubeAudioFormat] {
        if profile.requiresStreamingPoToken && response.streamingPoToken == nil {
            return response.formats.filter(\.isMuxedFallback)
        }
        return response.formats
    }
}
