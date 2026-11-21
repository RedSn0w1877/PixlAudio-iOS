import PixlModel

// What a ring code's lookup becomes (the Android `RingCodeSongs`): the code carries only the video id, so the receiver asks YouTube
// Music for that one video (the same `get_queue` call the music brain uses to name a track) and turns the answer into the payload the
// card and the library need. Needs the internet; a failure is nil and the screen offers the QR code, which carries the name itself.

/// Turns an 11-character video id into the song a card shows (title, artist, length, art). Nil when it cannot be looked up.
public protocol RingCodeLookup: Sendable {
    func resolve(videoId: String, nowMs: Int64) async -> SongTapPayload?
}

public enum RingCodeSongs {
    /// Art links the card may load: https on one of the same four hosts a beam's art may use, plain printable characters, at most this long.
    public static let maxArtUrl = 400

    /// What a ring code's lookup becomes: a payload with the video id and the text the card shows. Nil when there is no usable title.
    public static func payload(from row: RadioRow, nowMs: Int64) -> SongTapPayload? {
        let title = SongTapText.sanitize(row.title, maxBytes: SongTapPayloads.maxTitleBytes)
        if title.isEmpty || !SongTapPayloads.isVideoId(row.videoId) { return nil }
        var artist = SongTapText.sanitize(row.artistDisplay, maxBytes: SongTapPayloads.maxArtistBytes)
        if artist.isEmpty { artist = SongTapPayloads.unknownArtist }
        let seconds = Int64(max(row.durationSec, 0))
        let duration = Int(min(seconds * 1000, Int64(SongTapPayloads.maxDurationMs)))
        return SongTapPayload(v: SongTapPayloads.version, ts: max(nowMs, 0), ytVideoId: row.videoId, spotifyId: nil, isrc: nil,
                              title: title, artist: artist, durationMs: duration, artUrl: artFor(row))
    }

    /// The row's own cover when it is on an allowed host, else the video's thumbnail.
    public static func artFor(_ row: RadioRow) -> String? {
        if let own = row.thumbnailUrl, isAllowedArt(own) { return own }
        return "https://i.ytimg.com/vi/\(row.videoId)/hqdefault.jpg"
    }

    public static func isAllowedArt(_ url: String) -> Bool {
        let b = Array(url.utf8)
        let prefix = Array("https://".utf8)
        if b.count > maxArtUrl || b.count < prefix.count || Array(b[0..<prefix.count]) != prefix { return false }
        for c in b where c < 0x21 || c > 0x7E || c == 0x22 || c == 0x5C || c == 0x3C || c == 0x3E { return false }
        guard let hostEnd = b[prefix.count...].firstIndex(of: 0x2F) else { return false }
        let host = Array(b[prefix.count..<hostEnd])
        return SongTapPayloads.artHosts.contains { Array($0.utf8) == host }
    }
}
