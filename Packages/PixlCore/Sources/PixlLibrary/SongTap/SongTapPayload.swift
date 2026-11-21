// The thing a beam carries (Song Tap): which song, in the fewest bytes (ids, title, artist, art link). No audio, no
// account, no device identity: each phone streams the song itself. A transliteration of the Android `:songtap`
// module's `SongTapPayload.kt`.
//
// Wire form, one canonical JSON object in UTF-8, keys in this order, no whitespace, optional keys left out when
// absent, only `"` and `\` ever escaped (text with control or bidirectional characters is rejected, so nothing else
// needs escaping):
//
// `{"v":1,"ts":<ms>,"yt":"<11>","sp":"<22>","isrc":"<12>","t":"<title>","a":"<artist>","d":<ms>,"art":"<url>"}`
//
// `decode` accepts exactly what `encode` writes and nothing else, so the bytes a phone signs are the bytes the other
// phone parses. Hard cap `maxBytes` bytes.

/// A song on the table.
public struct SongTapPayload: Sendable, Hashable {
    public var v: Int
    /// When the sender made it, Unix milliseconds on the sender's clock.
    public var ts: Int64
    /// The YouTube Music video the song plays from: 11 characters of `A-Z a-z 0-9 _ -`. Nil for a song the sender only
    /// knows from Spotify (not matched to a video yet): the receiver then finds the video itself. At least one of
    /// `ytVideoId` and `spotifyId` is always present.
    public var ytVideoId: String?
    /// The Spotify track id (22 base62 characters), when the sender knows it.
    public var spotifyId: String?
    /// The recording code (12 characters of `A-Z 0-9`), when the sender knows it.
    public var isrc: String?
    public var title: String
    public var artist: String
    public var durationMs: Int
    /// `https` only, on an allow-listed host (see `SongTapPayloads.artHosts`); nil when there is no art.
    public var artUrl: String?

    public init(v: Int, ts: Int64, ytVideoId: String?, spotifyId: String?, isrc: String?, title: String, artist: String,
                durationMs: Int, artUrl: String?) {
        self.v = v
        self.ts = ts
        self.ytVideoId = ytVideoId
        self.spotifyId = spotifyId
        self.isrc = isrc
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.artUrl = artUrl
    }

    /// What identifies the song in a session: the video id, or the Spotify id when there is no video yet.
    public var songKey: String { ytVideoId ?? spotifyId ?? "" }
}

/// Why a payload was refused.
public enum SongTapPayloadReject: String, Sendable, CaseIterable {
    case tooLarge = "too_large"
    case notUtf8 = "not_utf8"
    case syntax = "syntax"
    case version = "version"
    case badTimestamp = "bad_timestamp"
    case noSongId = "no_song_id"
    case badVideoId = "bad_video_id"
    case badSpotifyId = "bad_spotify_id"
    case badIsrc = "bad_isrc"
    case badTitle = "bad_title"
    case badArtist = "bad_artist"
    case badDuration = "bad_duration"
    case badArtUrl = "bad_art_url"

    public var code: String { rawValue }
}

public enum SongTapPayloadDecode: Sendable, Equatable {
    case ok(SongTapPayload)
    case rejected(SongTapPayloadReject)
}

/// Rules, encoding and decoding of payloads.
public enum SongTapPayloads {
    public static let version = 1
    public static let maxBytes = 400
    public static let maxTitleBytes = 100
    public static let maxArtistBytes = 80
    public static let maxArtUrlBytes = 110
    public static let maxDurationMs = 86_400_000
    public static let unknownArtist = "Unknown artist"

    /// The only hosts a beam's art link may point at, matched exactly.
    public static let artHosts: [String] = ["i.scdn.co", "i.ytimg.com", "lh3.googleusercontent.com", "yt3.ggpht.com"]

    // MARK: Field validators

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
    }

    public static func isVideoId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        if b.count != 11 { return false }
        for c in b where !isAlnum(c) && c != 0x5F && c != 0x2D { return false }
        return true
    }

    public static func isSpotifyId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        if b.count != 22 { return false }
        for c in b where !isAlnum(c) { return false }
        return true
    }

    public static func isIsrc(_ s: String) -> Bool {
        let b = Array(s.utf8)
        if b.count != 12 { return false }
        for c in b where !((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)) { return false }
        return true
    }

    private static func isUrlChar(_ c: UInt8) -> Bool {
        if isAlnum(c) { return true }
        switch c {
        case 0x2D, 0x2E, 0x5F, 0x7E, 0x2F, 0x3F, 0x26, 0x3D, 0x25, 0x2B, 0x2C, 0x3A, 0x3B, 0x40, 0x21, 0x24, 0x2A, 0x27, 0x28, 0x29:
            // - . _ ~ / ? & = % + , : ; @ ! $ * ' ( )
            return true
        default:
            return false
        }
    }

    /// `https://<allow-listed host>/<path>`, printable ASCII only, at most `maxArtUrlBytes` bytes.
    public static func isAllowedArtUrl(_ s: String) -> Bool {
        let b = Array(s.utf8)
        if b.count > maxArtUrlBytes { return false }
        let prefix = Array("https://".utf8)
        if b.count < prefix.count || Array(b[0..<prefix.count]) != prefix { return false }
        for c in b where !isUrlChar(c) { return false }
        var hostEnd = -1
        var k = prefix.count
        while k < b.count {
            if b[k] == 0x2F { hostEnd = k; break }
            k += 1
        }
        if hostEnd < 0 || hostEnd == b.count - 1 { return false }
        let host = String(decoding: b[prefix.count..<hostEnd], as: UTF8.self)
        return artHosts.contains { Array($0.utf8) == Array(host.utf8) }
    }

    /// The first rule `p` breaks, or nil when it is a payload a phone may send and accept.
    public static func validate(_ p: SongTapPayload) -> SongTapPayloadReject? {
        if p.v != version { return .version }
        if p.ts < 0 { return .badTimestamp }
        if p.ytVideoId == nil && p.spotifyId == nil { return .noSongId }
        if let yt = p.ytVideoId, !isVideoId(yt) { return .badVideoId }
        if let sp = p.spotifyId, !isSpotifyId(sp) { return .badSpotifyId }
        if let isrc = p.isrc, !isIsrc(isrc) { return .badIsrc }
        if !SongTapText.isClean(SongTapText.toCodePoints(p.title), maxBytes: maxTitleBytes) { return .badTitle }
        if !SongTapText.isClean(SongTapText.toCodePoints(p.artist), maxBytes: maxArtistBytes) { return .badArtist }
        if p.durationMs < 0 || p.durationMs > maxDurationMs { return .badDuration }
        if let art = p.artUrl, !isAllowedArtUrl(art) { return .badArtUrl }
        return nil
    }

    // MARK: Encode

    private static func appendQuoted(_ out: inout [UInt8], _ text: String) {
        out.append(0x22)
        for c in text.utf8 {
            if c == 0x22 || c == 0x5C { out.append(0x5C) }
            out.append(c)
        }
        out.append(0x22)
    }

    private static func appendAscii(_ out: inout [UInt8], _ text: String) {
        out.append(contentsOf: Array(text.utf8))
    }

    /// The canonical bytes of `p`, or nil when `p` breaks a rule or is over `maxBytes`.
    public static func encode(_ p: SongTapPayload) -> [UInt8]? {
        if validate(p) != nil { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(256)
        appendAscii(&out, "{\"v\":"); appendAscii(&out, String(p.v))
        appendAscii(&out, ",\"ts\":"); appendAscii(&out, String(p.ts))
        if let yt = p.ytVideoId { appendAscii(&out, ",\"yt\":"); appendQuoted(&out, yt) }
        if let sp = p.spotifyId { appendAscii(&out, ",\"sp\":"); appendQuoted(&out, sp) }
        if let isrc = p.isrc { appendAscii(&out, ",\"isrc\":"); appendQuoted(&out, isrc) }
        appendAscii(&out, ",\"t\":"); appendQuoted(&out, p.title)
        appendAscii(&out, ",\"a\":"); appendQuoted(&out, p.artist)
        appendAscii(&out, ",\"d\":"); appendAscii(&out, String(p.durationMs))
        if let art = p.artUrl { appendAscii(&out, ",\"art\":"); appendQuoted(&out, art) }
        out.append(0x7D)
        return out.count > maxBytes ? nil : out
    }

    // MARK: Decode

    private struct Cursor {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        mutating func lit(_ text: String) -> Bool {
            let t = Array(text.utf8)
            if i + t.count > b.count { return false }
            for k in 0..<t.count where b[i + k] != t[k] { return false }
            i += t.count
            return true
        }

        /// A bare non-negative integer without sign, leading zeros or more than `maxDigits` digits; -1 on error.
        mutating func number(_ maxDigits: Int) -> Int64 {
            let start = i
            var v: Int64 = 0
            while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 {
                v = v * 10 + Int64(b[i] - 0x30)
                i += 1
                if i - start > maxDigits { return -1 }
            }
            let digits = i - start
            if digits == 0 { return -1 }
            if digits > 1 && b[start] == 0x30 { return -1 }
            return v
        }

        /// A quoted string: `\"` and `\\` are the only escapes; the raw bytes between the quotes are returned as text.
        mutating func string() -> String? {
            if i >= b.count || b[i] != 0x22 { return nil }
            i += 1
            var raw: [UInt8] = []
            while true {
                if i >= b.count { return nil }
                let c = b[i]
                i += 1
                if c == 0x22 { break }
                if c == 0x5C {
                    if i >= b.count { return nil }
                    let e = b[i]
                    i += 1
                    if e != 0x22 && e != 0x5C { return nil }
                    raw.append(e)
                } else {
                    raw.append(c)
                }
            }
            guard let cps = SongTapText.decodeUtf8(raw) else { return nil }
            return SongTapText.fromCodePoints(cps)
        }
    }

    public static func decode(_ bytes: [UInt8]) -> SongTapPayloadDecode {
        if bytes.count > maxBytes { return .rejected(.tooLarge) }
        if SongTapText.decodeUtf8(bytes) == nil { return .rejected(.notUtf8) }
        var c = Cursor(bytes)
        let bad = SongTapPayloadDecode.rejected(.syntax)

        if !c.lit("{\"v\":") { return bad }
        let v = c.number(3)
        if v < 0 { return bad }
        if !c.lit(",\"ts\":") { return bad }
        let ts = c.number(15)
        if ts < 0 { return bad }
        var yt: String?
        if c.lit(",\"yt\":") { guard let s = c.string() else { return bad }; yt = s }
        var sp: String?
        if c.lit(",\"sp\":") { guard let s = c.string() else { return bad }; sp = s }
        var isrc: String?
        if c.lit(",\"isrc\":") { guard let s = c.string() else { return bad }; isrc = s }
        if !c.lit(",\"t\":") { return bad }
        guard let title = c.string() else { return bad }
        if !c.lit(",\"a\":") { return bad }
        guard let artist = c.string() else { return bad }
        if !c.lit(",\"d\":") { return bad }
        let d = c.number(9)
        if d < 0 { return bad }
        var art: String?
        if c.lit(",\"art\":") { guard let s = c.string() else { return bad }; art = s }
        if !c.lit("}") { return bad }
        if c.i != bytes.count { return bad }
        let payload = SongTapPayload(v: Int(v), ts: ts, ytVideoId: yt, spotifyId: sp, isrc: isrc, title: title, artist: artist,
                                     durationMs: Int(d), artUrl: art)
        if let reason = validate(payload) { return .rejected(reason) }
        // The byte-for-byte check that makes "accepted" mean "exactly what encode writes".
        guard let again = encode(payload), again == bytes else { return bad }
        return .ok(payload)
    }

    // MARK: Building a payload from what the phone knows

    /// A payload for the song that is playing: text cleaned and cut to fit, ids kept only when they are well formed, and
    /// the optional parts dropped (art link first, then the Spotify id, then the recording code) until it is at most
    /// `maxBytes`. Nil when there is neither a valid video id nor a valid Spotify id, or no title.
    public static func make(nowMs: Int64, ytVideoId: String?, spotifyId: String?, isrc: String?, title: String, artist: String,
                            durationMs: Int64, artUrl: String?) -> SongTapPayload? {
        let video = ytVideoId.flatMap { isVideoId($0) ? $0 : nil }
        let spotify = spotifyId.flatMap { isSpotifyId($0) ? $0 : nil }
        if video == nil && spotify == nil { return nil }
        let cleanTitle = SongTapText.sanitize(title, maxBytes: maxTitleBytes)
        if cleanTitle.unicodeScalars.isEmpty { return nil }
        var cleanArtist = SongTapText.sanitize(artist, maxBytes: maxArtistBytes)
        if cleanArtist.unicodeScalars.isEmpty { cleanArtist = unknownArtist }
        let clampedDuration = durationMs < 0 ? 0 : (durationMs > Int64(maxDurationMs) ? maxDurationMs : Int(durationMs))
        var full = SongTapPayload(
            v: version, ts: nowMs < 0 ? 0 : nowMs, ytVideoId: video, spotifyId: spotify,
            isrc: isrc.flatMap { isIsrc($0) ? $0 : nil },
            title: cleanTitle, artist: cleanArtist, durationMs: clampedDuration,
            artUrl: artUrl.flatMap { isAllowedArtUrl($0) ? $0 : nil })
        if encode(full) != nil { return full }
        full.artUrl = nil
        if encode(full) != nil { return full }
        // The Spotify id goes only when a video id stays, so the song can still be named.
        if full.ytVideoId != nil {
            full.spotifyId = nil
            if encode(full) != nil { return full }
        }
        full.isrc = nil
        return encode(full) != nil ? full : nil
    }
}
