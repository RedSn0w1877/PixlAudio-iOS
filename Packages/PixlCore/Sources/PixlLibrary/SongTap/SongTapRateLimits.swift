// What a receiver lets in (Song Tap): one accepted beam per 3 seconds, 10 a minute, 30 an hour, the same video id not
// twice within 60 seconds, and a sender that was undone twice is muted for an hour. A transliteration of
// `SongTapRateLimits.kt`.
//
// An immutable value: `admit` only reads, `accepted` and `undone` return the next value. Held in memory for the
// process only.

/// Why a beam was not accepted, when the limits say no.
public enum SongTapLimitVerdict: String, Sendable {
    case allowed = "allowed"
    case tooSoon = "too_soon"
    case minuteLimit = "minute_limit"
    case hourLimit = "hour_limit"
    case duplicate = "duplicate"
    case muted = "muted"

    public var code: String { rawValue }
}

public struct SongTapRateLimits: Sendable, Equatable {
    public static let minGapMs: Int64 = 3_000
    public static let perMinute = 10
    public static let perHour = 30
    public static let sameSongMs: Int64 = 60_000
    public static let undosToMute = 2
    public static let muteMs: Int64 = 3_600_000
    private static let minuteMs: Int64 = 60_000
    private static let hourMs: Int64 = 3_600_000

    private struct Seen: Sendable, Equatable { let id: String; let at: Int64 }
    private struct Count: Sendable, Equatable { let key: Int32; let n: Int }
    private struct Mute: Sendable, Equatable { let key: Int32; let until: Int64 }

    private var acceptedAt: [Int64]
    private var recentVideos: [Seen]
    private var undoCounts: [Count]
    private var mutedUntil: [Mute]

    public init() {
        acceptedAt = []
        recentVideos = []
        undoCounts = []
        mutedUntil = []
    }

    public func admit(nowMs: Int64, videoId: String, senderKey: Int32) -> SongTapLimitVerdict {
        for m in mutedUntil where m.key == senderKey && m.until > nowMs { return .muted }
        if let last = acceptedAt.last, nowMs - last < Self.minGapMs { return .tooSoon }
        for s in recentVideos where s.id == videoId && nowMs - s.at < Self.sameSongMs { return .duplicate }
        var inMinute = 0
        var inHour = 0
        for at in acceptedAt {
            if nowMs - at < Self.minuteMs { inMinute += 1 }
            if nowMs - at < Self.hourMs { inHour += 1 }
        }
        if inMinute >= Self.perMinute { return .minuteLimit }
        if inHour >= Self.perHour { return .hourLimit }
        return .allowed
    }

    /// A beam of `videoId` was accepted at `nowMs`.
    public func accepted(nowMs: Int64, videoId: String) -> SongTapRateLimits {
        var next = self
        var times = acceptedAt.filter { nowMs - $0 < Self.hourMs }
        times.append(nowMs)
        if times.count > Self.perHour { times.removeFirst(times.count - Self.perHour) }
        next.acceptedAt = times
        var videos = recentVideos.filter { $0.id != videoId && nowMs - $0.at < Self.sameSongMs }
        videos.append(Seen(id: videoId, at: nowMs))
        next.recentVideos = videos
        next.mutedUntil = mutedUntil.filter { $0.until > nowMs }
        return next
    }

    /// An offer was let in but did not end in a saved song (nothing found, the save failed). It still cost a network
    /// search, so it counts towards the gap, the minute and the hour like an accepted beam; the song itself is not
    /// remembered, so the same song can be tried again once the gap has passed.
    public func attempted(nowMs: Int64) -> SongTapRateLimits {
        var next = self
        var times = acceptedAt.filter { nowMs - $0 < Self.hourMs }
        times.append(nowMs)
        if times.count > Self.perHour { times.removeFirst(times.count - Self.perHour) }
        next.acceptedAt = times
        next.mutedUntil = mutedUntil.filter { $0.until > nowMs }
        return next
    }

    /// The listener undid a beam from `senderKey`; the second undo mutes that sender for an hour. Key 0 means the
    /// sender is not known (a QR code carries no key), and not knowing who it was, nobody is muted for it: the rate
    /// limits above still apply.
    public func undone(nowMs: Int64, senderKey: Int32) -> SongTapRateLimits {
        if senderKey == 0 { return self }
        var next = self
        let before = undoCounts.first { $0.key == senderKey }?.n ?? 0
        let count = before + 1
        var others = undoCounts.filter { $0.key != senderKey }
        if count >= Self.undosToMute {
            next.undoCounts = others
            var muted = mutedUntil.filter { $0.key != senderKey }
            muted.append(Mute(key: senderKey, until: nowMs + Self.muteMs))
            next.mutedUntil = muted
        } else {
            others.append(Count(key: senderKey, n: count))
            next.undoCounts = others
        }
        return next
    }
}
