// What the player knows about a play (docs/brain-spec.md, 4.2): which track it is, how it came to play, where it
// was started from, and how it ended. Plain values and pure rules, so the app's tracker only carries facts and the
// reason table is unit-tested without a player. A port of Android's `PlayContext.kt`, the brain half of its
// `ListeningStatsTracker.kt` (`BrainPlay`) and `TrackCatalog.kt`.

import Foundation
import PixlModel

/// What is known about a play when it starts. On iOS the queue entry holds the whole `Song`, so the context carries
/// the track's own facts and the recorder needs no library lookup.
public struct PlayContext: Sendable, Equatable {
    public var title: String
    /// The artist line as shown: may name several artists.
    public var artistDisplay: String
    /// Credited artists, ONE name each, primary first. Empty when only the display line is known.
    public var artists: [String]
    /// A real Spotify track id; nil for a track that has none (a YouTube Music track, a local file).
    public var spotifyId: String?
    /// The YouTube audio id the track plays from, when the song itself names it (`yt:` songs).
    public var videoId: String?
    /// True when the library has a row for the song.
    public var inLibrary: Bool
    /// `StartReason` code.
    public var startReason: Int32
    /// Surface, surface id, list id, slot and arm of the queue entry; nil when it has none.
    public var tag: BrainItemTag?
    public var shuffle: Bool
    public var repeatOne: Bool
    /// `Route` code.
    public var route: Int32
    public var offline: Bool

    public init(title: String, artistDisplay: String, artists: [String] = [], spotifyId: String? = nil,
                videoId: String? = nil, inLibrary: Bool = true, startReason: Int32 = StartReason.unknown,
                tag: BrainItemTag? = nil, shuffle: Bool = false, repeatOne: Bool = false, route: Int32 = Route.unknown,
                offline: Bool = false) {
        self.title = title
        self.artistDisplay = artistDisplay
        self.artists = artists
        self.spotifyId = spotifyId
        self.videoId = videoId
        self.inLibrary = inLibrary
        self.startReason = startReason
        self.tag = tag
        self.shuffle = shuffle
        self.repeatOne = repeatOne
        self.route = route
        self.offline = offline
    }

    public var isEngineOwned: Bool { tag?.isEngineOwned == true }

    /// ONE artist name: the first credited artist, the name the queue entry carries, or the display line.
    public var primaryArtist: String {
        if let first = artists.first, !BrainText.isBlank(first) { return first }
        if let name = tag?.primaryArtist, !BrainText.isBlank(name) { return name }
        return artistDisplay
    }

    /// The context of `song` as the queue holds it. `inLibrary` is the app's answer to "does the library have a row
    /// for this id"; `videoId` the YouTube audio id of a `yt:` song.
    public static func of(song: Song, inLibrary: Bool, videoId: String?, tag: BrainItemTag?, startReason: Int32,
                          shuffle: Bool, repeatOne: Bool, route: Int32 = Route.unknown, offline: Bool = false) -> PlayContext {
        var names: [String] = []
        let ordered = song.artists.filter(\.isPrimary) + song.artists.filter { !$0.isPrimary }
        for artist in ordered where !BrainText.isBlank(artist.name) {
            if !names.contains(where: { BrainKey.sameBytes($0, artist.name) }) { names.append(artist.name) }
        }
        var spotifyId = song.spotifyId
        if let id = spotifyId, BrainText.isBlank(id) || TrackCatalog.isSyntheticId(id) { spotifyId = nil }
        return PlayContext(title: song.title, artistDisplay: song.artist, artists: names, spotifyId: spotifyId,
                           videoId: videoId, inLibrary: inLibrary, startReason: startReason, tag: tag, shuffle: shuffle,
                           repeatOne: repeatOne, route: route, offline: offline)
    }
}

/// One play attempt as the tracker saw it end: raw facts, nothing derived.
public struct FinishedPlay: Sendable, Equatable {
    /// The id the song played under.
    public var songId: String
    public var context: PlayContext
    /// Wall clock, UTC, when the play started.
    public var startedAtMs: Int64
    /// Audible milliseconds (time spent playing, not the position).
    public var playedMs: Int64
    /// 0 when unknown.
    public var durationMs: Int64
    /// `EndReason` code.
    public var endReason: Int32
    /// `EventFlags` bits set while it played (liked, replayed, ...); shuffle and repeat-one are added by the recorder.
    public var flags: Int32
    /// Minutes east of UTC when it started.
    public var tzOffsetMin: Int32

    public init(songId: String, context: PlayContext, startedAtMs: Int64, playedMs: Int64, durationMs: Int64,
                endReason: Int32, flags: Int32 = 0, tzOffsetMin: Int32 = 0) {
        self.songId = songId
        self.context = context
        self.startedAtMs = startedAtMs
        self.playedMs = playedMs
        self.durationMs = durationMs
        self.endReason = endReason
        self.flags = flags
        self.tzOffsetMin = tzOffsetMin
    }
}

/// One play in flight, as the music brain will record it: the item's context and the time actually spent playing.
/// The tracker keeps one beside its legacy session, whose shape and five-second floor belong to the legacy stores.
/// A value with no clock: the caller passes monotonic and wall-clock milliseconds in.
public struct OpenPlay: Sendable, Equatable {
    public static let seekSignalMinPlayedMs: Int64 = 30_000
    public static let seekBackMinMs: Int64 = 10_000
    public static let replayPositionMs: Int64 = 3_000
    /// A "replay" that is left by Previous within this long was the way out, not a wish to hear the track again.
    public static let replayConfirmMs: Int64 = 5_000

    public let songId: String
    public var context: PlayContext
    public let startedAtEpochMs: Int64
    public let tzOffsetMin: Int32
    public private(set) var durationMs: Int64
    public private(set) var isPlaying: Bool
    private var lastRealtimeMs: Int64
    public private(set) var playedMs: Int64 = 0
    public private(set) var flags: Int32 = 0
    /// True once it made a sound.
    public private(set) var everPlayed: Bool
    /// When a seek to the start first flagged this play as replayed (monotonic); nil when it never did.
    private var replayFlaggedAtRealtimeMs: Int64?

    public init(songId: String, context: PlayContext, startedAtEpochMs: Int64, tzOffsetMin: Int32, durationMs: Int64,
                isPlaying: Bool, realtimeMs: Int64) {
        self.songId = songId
        self.context = context
        self.startedAtEpochMs = startedAtEpochMs
        self.tzOffsetMin = tzOffsetMin
        self.durationMs = durationMs > 0 ? durationMs : 0
        self.isPlaying = isPlaying
        lastRealtimeMs = realtimeMs
        everPlayed = isPlaying
    }

    /// Playback started or paused, or the length became known. Returns true when the play should be written down
    /// as "open" (it made its first sound, or it paused): a process death then still leaves a `killed` event.
    @discardableResult
    public mutating func update(realtimeMs: Int64, playing: Bool, durationMs duration: Int64 = 0) -> Bool {
        let wasPlaying = isPlaying
        let hadPlayed = everPlayed
        if isPlaying { playedMs += max(realtimeMs - lastRealtimeMs, 0) }
        isPlaying = playing
        if playing { everPlayed = true }
        lastRealtimeMs = realtimeMs
        if duration > 0 { durationMs = duration }
        return (playing && !hadPlayed) || (wasPlaying && !playing)
    }

    /// Something happened to the song while it played (liked, saved, added to a playlist, "Not for me").
    public mutating func mark(_ flag: Int32) { flags |= flag }

    /// Takes a flag back (Undo of "Don't count this").
    public mutating func unmark(_ flag: Int32) { flags &= ~flag }

    /// A seek inside the track. Back to the start after 30 s of listening is a replay; back by 10 s or more after
    /// 30 s is a seek-back (4.3).
    public mutating func seek(fromPositionMs: Int64, toPositionMs: Int64, realtimeMs: Int64) {
        update(realtimeMs: realtimeMs, playing: isPlaying)
        if playedMs < Self.seekSignalMinPlayedMs { return }
        if toPositionMs <= Self.replayPositionMs && fromPositionMs >= Self.seekSignalMinPlayedMs {
            if flags & EventFlags.replayed == 0 { replayFlaggedAtRealtimeMs = realtimeMs }
            flags |= EventFlags.replayed
        } else if fromPositionMs - toPositionMs >= Self.seekBackMinMs {
            flags |= EventFlags.seekBack
        }
    }

    /// The play as it stands, with `endReason`.
    public func snapshot(endReason: Int32) -> FinishedPlay {
        FinishedPlay(songId: songId, context: context, startedAtMs: startedAtEpochMs, playedMs: playedMs,
                     durationMs: durationMs, endReason: endReason, flags: flags, tzOffsetMin: tzOffsetMin)
    }

    /// Ends the play. Nil when it is not a play attempt at all: an item that never made a sound and was not ended
    /// by the listener or by an error (a restored, paused queue; a queue that was cleared). A play that never made
    /// a sound but was skipped or failed is returned flagged `neverAudible`, which is worth nothing (4.3).
    public mutating func finish(endReason: Int32, realtimeMs: Int64) -> FinishedPlay? {
        update(realtimeMs: realtimeMs, playing: isPlaying)
        // Previous pressed twice goes back a track: the first press seeks to the start (which looks like a replay),
        // the second leaves. That is the way out, not a like.
        if endReason == EndReason.prev, let flaggedAt = replayFlaggedAtRealtimeMs,
           realtimeMs - flaggedAt < Self.replayConfirmMs {
            flags &= ~EventFlags.replayed
        }
        let ended = endReason == EndReason.next || endReason == EndReason.prev || endReason == EndReason.pickedOther
            || endReason == EndReason.queueEdit || endReason == EndReason.error
        if !everPlayed && !ended { return nil }
        if playedMs <= 0 { flags |= EventFlags.neverAudible }
        return snapshot(endReason: endReason)
    }
}

/// The reason table of docs/brain-spec.md, 4.2: what a player event says about the play that ends and the one that
/// starts. Pure, so the table is unit-tested without a player.
public enum PlayReasons {
    /// The four kinds of track change (Media3's `MEDIA_ITEM_TRANSITION_REASON_*` on Android; `kind` maps the iOS
    /// engine's callbacks onto them).
    public static let transitionRepeat: Int32 = 0
    public static let transitionAuto: Int32 = 1
    public static let transitionSeek: Int32 = 2
    public static let transitionPlaylistChanged: Int32 = 3

    public struct Reasons: Sendable, Equatable {
        public let end: Int32
        public let start: Int32

        public init(end: Int32, start: Int32) {
            self.end = end
            self.start = start
        }
    }

    /// Which kind of change an iOS engine callback is: the engine moved on by itself (`automatic`), the queue was
    /// replaced or edited in the same turn (`queueChanged`), or the listener moved inside the queue.
    public static func kind(automatic: Bool, queueChanged: Bool) -> Int32 {
        if automatic { return transitionAuto }
        return queueChanged ? transitionPlaylistChanged : transitionSeek
    }

    /// `oldIndex` and `newIndex` are queue indices, -1 when unknown. `oldQueueSize` and `newQueueSize` tell a queue
    /// edit (the current item was removed: one item fewer) from a new queue.
    public static func forTransition(reason: Int32, oldIndex: Int, newIndex: Int, oldQueueSize: Int, newQueueSize: Int,
                                     newItemIsEnginePick: Bool, isRestoring: Bool) -> Reasons {
        if reason == transitionAuto {
            return Reasons(end: EndReason.trackDone, start: newItemIsEnginePick ? StartReason.autoplay : StartReason.autoAdvance)
        }
        if reason == transitionRepeat { return Reasons(end: EndReason.trackDone, start: StartReason.autoAdvance) }
        if reason == transitionSeek {
            if oldIndex >= 0 && newIndex == oldIndex + 1 { return Reasons(end: EndReason.next, start: StartReason.next) }
            if oldIndex >= 0 && newIndex == oldIndex - 1 { return Reasons(end: EndReason.prev, start: StartReason.prev) }
            // 4.1 has no "pickedOther" start reason: picking an item of the queue is a tap.
            return Reasons(end: EndReason.pickedOther, start: StartReason.tap)
        }
        if reason == transitionPlaylistChanged {
            let removedCurrent = oldQueueSize > 1 && newQueueSize == oldQueueSize - 1
            return Reasons(end: removedCurrent ? EndReason.queueEdit : EndReason.pickedOther,
                           start: isRestoring ? StartReason.restore : StartReason.tap)
        }
        return Reasons(end: EndReason.unknown, start: StartReason.unknown)
    }

    /// A load that failed: the engine moved on by itself, but the track that ended did not play out.
    public static func afterFailure(newItemIsEnginePick: Bool) -> Reasons {
        Reasons(end: EndReason.error, start: newItemIsEnginePick ? StartReason.autoplay : StartReason.autoAdvance)
    }
}

/// Where a play the UI starts comes from, as a queue-entry tag (docs/brain-spec.md, 4.2).
public enum BrainSurfaces {
    public static func tag(_ surface: Int32, id: String? = nil) -> BrainItemTag {
        BrainItemTag(surface: Surface.nameOf(surface), surfaceId: id)
    }

    /// A playlist by its id. The id is the listener's own data: the log keeps a hash of it, not the id.
    public static func playlist(id: String) -> BrainItemTag { tag(Surface.playlist, id: hashedId(id)) }

    /// A track the listener put in the queue by hand ("Add to queue", "Play next").
    public static let manualQueue = tag(Surface.manualQueue)

    /// Lower-case hexadecimal of `fnv1a64(utf8(id))` (Java `Long.toHexString`).
    public static func hashedId(_ id: String) -> String {
        var bits = BrainHash.fnv1a64(id)
        if bits == 0 { return "0" }
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var reversed: [UInt8] = []
        while bits != 0 {
            reversed.append(digits[Int(bits & 0xF)])
            bits >>= 4
        }
        return String(decoding: reversed.reversed(), as: UTF8.self)
    }
}

/// What identity needs to know about one track: its keys, its artists (one name each), its length.
public struct TrackFacts: Sendable {
    public var keys: Ids.TrackKeys
    /// The key an event stores as `keyAtWrite`: the strongest one.
    public var keyAtWrite: String
    public var title: String
    public var primaryArtist: String
    public var otherArtists: [String]
    public var durationMs: Int64
    public var inLibrary: Bool
    public var spotifyId: String?
    public var videoId: String?
}

/// From a song, a `playable` row or a play's own context to `TrackFacts`.
public enum TrackCatalog {
    /// A YouTube Music import carries a synthetic id (22 lower-case hex characters), not a Spotify track id.
    public static func isSyntheticId(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The video id of a `yt:<videoId>` song id, or nil.
    public static func videoId(ofSongId songId: String) -> String? {
        let prefix = Array(EngineTrack.songIdPrefix.utf8)
        guard songId.utf8.count > prefix.count, songId.utf8.starts(with: prefix) else { return nil }
        return String(decoding: songId.utf8.dropFirst(prefix.count), as: UTF8.self)
    }

    /// A library row: its Spotify id when it is a real one, and its names.
    public static func facts(of song: Song) -> TrackFacts? {
        let primary = BrainLibraryIndex.primaryArtistName(song)
        var spotifyId = song.spotifyId
        if let id = spotifyId, BrainText.isBlank(id) || isSyntheticId(id) { spotifyId = nil }
        let keys = Ids.TrackKeys(spotifyId: spotifyId, nameKey: Ids.nameKey(primaryArtist: primary, rawTitle: song.title))
        guard let key = keys.s ?? keys.n else { return nil }
        var others: [String] = []
        for artist in song.artists where !BrainText.isBlank(artist.name) && !BrainKey.sameBytes(artist.name, primary) {
            if others.count >= PlayEvent.maxOtherAids { break }
            if !others.contains(where: { BrainKey.sameBytes($0, artist.name) }) { others.append(artist.name) }
        }
        return TrackFacts(keys: keys, keyAtWrite: key, title: song.title, primaryArtist: primary, otherArtists: others,
                          durationMs: song.duration, inLibrary: true, spotifyId: spotifyId, videoId: nil)
    }

    /// A track from outside the library, by its `playable` row.
    public static func facts(of record: PlayableRecord) -> TrackFacts? {
        let names = record.artists.map(\.name).filter { !BrainText.isBlank($0) }
        let primary = names.first ?? ""
        let keys = Ids.TrackKeys(videoId: record.videoId, nameKey: Ids.nameKey(primaryArtist: primary, rawTitle: record.title))
        guard let key = keys.y else { return nil }
        return TrackFacts(keys: keys, keyAtWrite: key, title: record.title, primaryArtist: primary,
                          otherArtists: Array(names.dropFirst().prefix(PlayEvent.maxOtherAids)),
                          durationMs: record.durationMs, inLibrary: false, spotifyId: nil, videoId: record.videoId)
    }

    /// What a play's own context says. A library track resolves by its Spotify id and its names; a track from
    /// outside the library by its YouTube audio id and its names (the keys its `playable` row would give).
    public static func facts(of context: PlayContext, durationMs: Int64) -> TrackFacts? {
        let primary = context.primaryArtist
        let nameKey = Ids.nameKey(primaryArtist: primary, rawTitle: context.title)
        let keys = context.inLibrary
            ? Ids.TrackKeys(spotifyId: context.spotifyId, nameKey: nameKey)
            : Ids.TrackKeys(spotifyId: context.spotifyId, videoId: context.videoId, nameKey: nameKey)
        guard let key = context.inLibrary ? (keys.s ?? keys.n) : (keys.y ?? keys.s ?? keys.n) else { return nil }
        var others: [String] = []
        for name in context.artists.dropFirst() where !BrainText.isBlank(name) && !BrainKey.sameBytes(name, primary) {
            if others.count >= PlayEvent.maxOtherAids { break }
            if !others.contains(where: { BrainKey.sameBytes($0, name) }) { others.append(name) }
        }
        return TrackFacts(keys: keys, keyAtWrite: key, title: context.title, primaryArtist: primary, otherArtists: others,
                          durationMs: durationMs, inLibrary: context.inLibrary, spotifyId: context.spotifyId,
                          videoId: context.videoId)
    }
}
