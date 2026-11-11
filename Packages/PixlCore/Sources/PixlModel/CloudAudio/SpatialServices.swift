// The two services behind Spatial audio and Enhanced audio, as the rest of the app sees them (cloud audio spec of
// 2026-11-10, section 6). Each is built by one part of the app and used through its protocol:
//
//   `SpatialLibrary`  : the cloud side. The local store of verified renders, the shared library in R2, the jobs
//                       that fill it, the background queue and the caps (spec 6.2, 6.4).
//   `SpatialPlayback` : the engine side. The on-device stage, which audio a song plays from, the in-song switch to a
//                       render, the route rule and the level rule (spec 6.3, 7).
//
// Who calls what:
// - The app's Spatial audio model (the one object the screens read) gives both services the settings (`apply`),
//   listens to both (`events`), and is the only caller of `SpatialLibrary.request` for the song that is playing.
// - The engine is handed the library, asks it for local files (`localRendition`) whenever it builds an item, and
//   listens to `events()` for a render that lands while its song plays. It never asks for a render to be made.
// - The library never looks at playback.
//
// Rules for implementations:
// - Every requirement is `async` and every value crossing it is `Sendable`, so an implementation may be an actor, a
//   main-actor class or a plain value. No requirement takes an `async` closure (a closure type declared here means
//   something else inside the app target, whose default isolation differs); changes come through `events()`.
// - `events()` hands out a new stream per call (`SpatialEventHub` does this); every stream gets every later event.
// - Nothing here may block: lookups answer from memory, work happens in the implementation's own tasks.

import Foundation
import Synchronization

// MARK: - The cloud side

/// A verified render in the local store: the file, and the manifest stored beside it.
public struct LocalRendition: Sendable, Hashable {
    public var key: RenditionKey
    /// The FLAC file (`…/CloudAudio/<videoId>/<slot>.flac`).
    public var fileURL: URL
    public var manifest: CloudLibraryManifest

    public init(key: RenditionKey, fileURL: URL, manifest: CloudLibraryManifest) {
        self.key = key
        self.fileURL = fileURL
        self.manifest = manifest
    }

    /// What the app gives back while it plays (4 dB for a spatial render, 0 for Enhanced).
    public var headroomDb: Double { manifest.headroomDb }
    /// The file's length as the manifest says (the in-song switch checks it against the song before lining up).
    public var durationMs: Int64? { manifest.audio?.durationMs }
    public var sampleRate: Int? { manifest.audio?.sampleRate }
    public var bytes: Int64 { manifest.audio?.bytes ?? 0 }
}

/// Why a rendition is asked for (the library orders its work by it; a Sing job still goes before all of them).
public enum RenditionRequestReason: String, Sendable, Hashable {
    /// The song is playing with Spatial audio active (or Enhanced wanted) and has no local rendition.
    case playing
    /// The background queue picked it (spec 6.4).
    case ahead
}

/// One rendition wanted for one song (spec 6.2).
public struct RenditionRequest: Sendable, Hashable {
    /// The library song: what the job prepares and uploads when the shared library has no render.
    public var song: Song
    /// The YouTube video the song plays from (a Spotify song's match).
    public var videoId: String
    public var kind: RenditionKind
    public var reason: RenditionRequestReason

    public init(song: Song, videoId: String, kind: RenditionKind, reason: RenditionRequestReason = .playing) {
        self.song = song
        self.videoId = videoId
        self.kind = kind
        self.reason = reason
    }

    public var key: RenditionKey { RenditionKey(videoId: videoId, kind: kind) }
}

/// What the local store holds, and what library jobs have used of their caps.
public struct CloudAudioUsage: Sendable, Hashable {
    /// Songs with at least one verified rendition on this phone ("Songs ready: N").
    public var songsReady: Int
    /// The size of every rendition file on this phone.
    public var bytes: Int64
    /// What library jobs spent this month, in millionths of a dollar (for the Developer mode rows).
    public var spentThisMonthMicroUSD: Int64
    /// Songs the background queue sent today.
    public var sentToday: Int

    public init(songsReady: Int = 0, bytes: Int64 = 0, spentThisMonthMicroUSD: Int64 = 0, sentToday: Int = 0) {
        self.songsReady = songsReady
        self.bytes = bytes
        self.spentThisMonthMicroUSD = spentThisMonthMicroUSD
        self.sentToday = sentToday
    }

    public static let empty = CloudAudioUsage()
}

public enum SpatialLibraryEvent: Sendable, Hashable {
    /// A rendition's status moved (queued, processing, failed, back to none after "Remove downloaded renders"…).
    case statusChanged(RenditionKey, RenditionStatus)
    /// A verified render is now in the local store. Sent in addition to `statusChanged(_, .ready)`.
    case renditionReady(LocalRendition)
    /// A local render is gone (evicted, removed by the person, or of an older library version).
    case renditionRemoved(RenditionKey)
    case usageChanged(CloudAudioUsage)
}

/// The cloud side of Spatial audio and Enhanced audio.
public protocol SpatialLibrary: Sendable {
    /// The settings in force: called once at launch and after every change. The library follows `cloud`,
    /// `prepareAhead`, `enhancedEnabled`, the profile the background queue prepares, the storage budget and the caps.
    func apply(_ settings: CloudAudioSettings) async

    /// Step 1 of spec 6.2: the verified local render, or nil. Called whenever the player builds an item, so it
    /// answers from memory: no network, no hashing, no directory scan.
    func localRendition(_ key: RenditionKey) async -> LocalRendition?

    /// Every local rendition of a song (Developer mode's per-song diagnostics read their manifests).
    func localRenditions(videoId: String) async -> [LocalRendition]

    /// Where the rendition stands: `ready`, `queued`, `processing`, `failed`, or `none`. Never `preview`: that is the
    /// player's fact, added by `RenditionStatus.shown`.
    func status(_ key: RenditionKey) async -> RenditionStatus

    /// Spec 6.2 for one rendition: the local store, else the shared library, else a job, as the settings, the network
    /// and the caps allow (with `spatial.cloud` off nothing leaves the phone and the answer is `none`). Asking again
    /// for something already on its way changes nothing. Returns the status now; later ones come through `events()`.
    @discardableResult
    func request(_ request: RenditionRequest) async -> RenditionStatus

    /// The rendition was played just now (the local store removes the least recently played first).
    func markPlayed(_ key: RenditionKey) async

    func usage() async -> CloudAudioUsage

    /// "Remove downloaded renders": deletes every local rendition (never anything in the shared library) and returns
    /// what is left.
    @discardableResult
    func removeAll() async -> CloudAudioUsage

    func events() async -> AsyncStream<SpatialLibraryEvent>
}

// MARK: - The engine side

/// What is audible for the current song.
public enum SpatialAudible: Sendable, Hashable {
    /// Plain stereo: the stream or the downloaded file (`enhanced`: the Enhanced file instead).
    case stereo(enhanced: Bool)
    /// The on-device stage, on top of the stream or of the Enhanced file.
    case onDevice(SpatialProfile, enhanced: Bool)
    /// A spatial cloud render, with the on-device stage bypassed.
    case render(SpatialProfile)

    /// The profile that is heard, if any.
    public var profile: SpatialProfile? {
        switch self {
        case .stereo: nil
        case .onDevice(let profile, _), .render(let profile): profile
        }
    }

    public var isCloudRender: Bool {
        if case .render = self { return true }
        return false
    }

    public var isOnDevice: Bool {
        if case .onDevice = self { return true }
        return false
    }
}

/// The player's side of Spatial audio at one moment. Never the position.
public struct SpatialPlaybackSnapshot: Sendable, Hashable {
    /// The current queue entry's song (nil: nothing is loaded).
    public var songId: String?
    /// The YouTube video its audio comes from, when it has one.
    public var videoId: String?
    /// The selection the player was given.
    public var selection: SpatialSelection
    /// Where the audio goes now.
    public var output: SpatialOutputKind
    /// The route rule's answer for `output` and the route mode in force.
    public var routePasses: Bool
    /// Sing's instrumental plays (Spatial audio stands aside for it).
    public var singInstrumentalOn: Bool
    public var audible: SpatialAudible

    public init(songId: String? = nil, videoId: String? = nil, selection: SpatialSelection = .off,
                output: SpatialOutputKind = .phoneSpeaker, routePasses: Bool = false, singInstrumentalOn: Bool = false,
                audible: SpatialAudible = .stereo(enhanced: false)) {
        self.songId = songId
        self.videoId = videoId
        self.selection = selection
        self.output = output
        self.routePasses = routePasses
        self.singInstrumentalOn = singInstrumentalOn
        self.audible = audible
    }

    /// Nothing loaded, Spatial audio off.
    public static let idle = SpatialPlaybackSnapshot()

    /// "Spatial active" (spec 6.3).
    public var isActive: Bool { selection.isOn && routePasses && !singInstrumentalOn }

    /// The rendition the cloud should be asked for while this plays: the selected profile's render of this video,
    /// when Spatial audio is active and that render is not already what plays. Nil otherwise.
    public var wantedRender: RenditionKey? {
        guard isActive, let profile = selection.profile, let videoId, audible != .render(profile) else { return nil }
        return RenditionKey(videoId: videoId, profile: profile)
    }
}

/// The engine side of Spatial audio and Enhanced audio.
public protocol SpatialPlayback: Sendable {
    /// The settings in force: called once at launch and after every change. The player follows `profile` (at once,
    /// with a short ramp), `route` and `enhancedEnabled`.
    func apply(_ settings: CloudAudioSettings) async

    /// What plays now.
    func snapshot() async -> SpatialPlaybackSnapshot

    /// Every later snapshot: sent when the song, the selection, the output, Sing's mode or what is audible changes.
    func events() async -> AsyncStream<SpatialPlaybackSnapshot>
}

// MARK: - The line under the profile list

/// The status line of the Spatial audio sheet for the song that is playing (spec 6.5).
public enum SpatialStatusLine: Sendable, Hashable {
    /// Nothing to say: Spatial audio is off, or nothing of it is heard.
    case none
    /// The on-device version plays and the cloud version is wanted.
    case onDeviceForNow
    /// The on-device version plays and no cloud version is coming (the cloud is off, or the last try failed).
    case onDeviceOnly
    /// The cloud render plays.
    case cloudVersion
    /// A profile is selected but the output is not headphones.
    case headphonesOnly
    /// A profile is selected but Sing's instrumental plays.
    case pausedForSing

    /// The spec's sentence (the English source text), where it has one. `onDeviceOnly` and `pausedForSing` have none
    /// in the spec: the screens choose what to show for them, if anything.
    public var text: String? {
        switch self {
        case .onDeviceForNow: "On your phone for now. The cloud version takes about a minute."
        case .cloudVersion: "Playing the cloud version."
        case .headphonesOnly: "Headphones only. Plug in to hear it."
        case .none, .onDeviceOnly, .pausedForSing: nil
        }
    }

    /// The line for what plays, whether the cloud may be asked (`spatial.cloud`), and the library's status of the
    /// selected profile's render.
    public static func line(for snapshot: SpatialPlaybackSnapshot, cloud: Bool, status: RenditionStatus) -> SpatialStatusLine {
        guard snapshot.selection.isOn, snapshot.songId != nil else { return .none }
        if !snapshot.routePasses { return .headphonesOnly }
        if snapshot.singInstrumentalOn { return .pausedForSing }
        switch snapshot.audible {
        case .render: return .cloudVersion
        case .onDevice: return cloud && status != .failed ? .onDeviceForNow : .onDeviceOnly
        case .stereo: return .none
        }
    }
}

// MARK: - Events

/// Hands every event to every stream it has given out. Thread-safe; `send` never blocks on a slow reader (a reader
/// that falls behind keeps the newest events).
public final class SpatialEventHub<Event: Sendable>: Sendable {
    private struct State {
        var nextId = 0
        var continuations: [Int: AsyncStream<Event>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let bufferSize: Int

    /// `bufferSize`: how many unread events a stream keeps (the newest ones).
    public init(bufferSize: Int = 64) {
        self.bufferSize = max(bufferSize, 1)
    }

    /// A new stream of every later event. `first`, when given, is delivered before them (the current state for a
    /// reader that starts late).
    public func stream(first: Event? = nil) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(bufferSize))
        if let first { continuation.yield(first) }
        let id = state.withLock { state -> Int in
            let id = state.nextId
            state.nextId += 1
            state.continuations[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in state.continuations[id] = nil }
        }
        return stream
    }

    public func send(_ event: Event) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    /// Ends every stream (the service is going away).
    public func finish() {
        let continuations = state.withLock { state -> [AsyncStream<Event>.Continuation] in
            let all = Array(state.continuations.values)
            state.continuations.removeAll()
            return all
        }
        for continuation in continuations { continuation.finish() }
    }

    /// How many streams are being read (tests).
    public var subscriberCount: Int { state.withLock { $0.continuations.count } }
}

// MARK: - No-op implementations

/// A library with nothing in it that never asks the cloud for anything: what the app runs on until the cloud side is
/// built, in UI tests, and wherever the feature is switched off.
public struct NoopSpatialLibrary: SpatialLibrary {
    public init() {}

    public func apply(_ settings: CloudAudioSettings) async {}
    public func localRendition(_ key: RenditionKey) async -> LocalRendition? { nil }
    public func localRenditions(videoId: String) async -> [LocalRendition] { [] }
    public func status(_ key: RenditionKey) async -> RenditionStatus { .none }
    @discardableResult
    public func request(_ request: RenditionRequest) async -> RenditionStatus { .none }
    public func markPlayed(_ key: RenditionKey) async {}
    public func usage() async -> CloudAudioUsage { .empty }
    @discardableResult
    public func removeAll() async -> CloudAudioUsage { .empty }
    public func events() async -> AsyncStream<SpatialLibraryEvent> { AsyncStream { $0.finish() } }
}

/// A player that knows nothing of Spatial audio: plain stereo, always.
public struct NoopSpatialPlayback: SpatialPlayback {
    public init() {}

    public func apply(_ settings: CloudAudioSettings) async {}
    public func snapshot() async -> SpatialPlaybackSnapshot { .idle }
    public func events() async -> AsyncStream<SpatialPlaybackSnapshot> { AsyncStream { $0.finish() } }
}
