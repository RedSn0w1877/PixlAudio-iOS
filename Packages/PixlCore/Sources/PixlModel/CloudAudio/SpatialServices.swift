// The two services behind Spatial audio, as the rest of the app sees them (cloud audio spec of 2026-11-10,
// section 6). Each is built by one part of the app and used through its protocol:
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
    /// The FLAC file (`…/CloudAudio/<videoId>/sp-<profile>.flac`).
    public var fileURL: URL
    public var manifest: CloudLibraryManifest

    public init(key: RenditionKey, fileURL: URL, manifest: CloudLibraryManifest) {
        self.key = key
        self.fileURL = fileURL
        self.manifest = manifest
    }

    /// What the app gives back while it plays (4 dB today).
    public var headroomDb: Double { manifest.headroomDb }
    /// The file's length as the manifest says (the in-song switch checks it against the song before lining up).
    public var durationMs: Int64? { manifest.audio?.durationMs }
    /// The render's rate: the uploaded file's, which may differ from the rate of the stream this phone plays. Line a
    /// render up with the song by media time, never by frame count across files.
    public var sampleRate: Int? { manifest.audio?.sampleRate }
    public var bytes: Int64 { manifest.audio?.bytes ?? 0 }
}

/// Why a rendition is asked for (the library orders its work by it; a Sing job still goes before all of them).
public enum RenditionRequestReason: String, Sendable, Hashable {
    /// The song is playing with Spatial audio active and has no local render of the selected profile.
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
    public var profile: SpatialProfile
    public var reason: RenditionRequestReason

    public init(song: Song, videoId: String, profile: SpatialProfile, reason: RenditionRequestReason = .playing) {
        self.song = song
        self.videoId = videoId
        self.profile = profile
        self.reason = reason
    }

    public var key: RenditionKey { RenditionKey(videoId: videoId, profile: profile) }
}

/// What the local store holds, and what library jobs have used of their caps.
public struct CloudAudioUsage: Sendable, Hashable {
    /// Songs with at least one verified render on this phone ("Songs ready: N").
    public var songsReady: Int
    /// The size of every render file on this phone.
    public var bytes: Int64
    /// What library jobs spent this month, in millionths of a dollar (their own sum, apart from Sing's; for the
    /// Developer mode rows).
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
    /// A rendition's status moved (queued, waiting for a network or for next month, processing, downloading, failed,
    /// back to none after "Remove downloaded renders"…).
    case statusChanged(RenditionKey, RenditionStatus)
    /// A verified render is now in the local store. Sent in addition to `statusChanged(_, .ready)`.
    case renditionReady(LocalRendition)
    /// A local render is gone (evicted, removed by the person, or of an older library version).
    case renditionRemoved(RenditionKey)
    case usageChanged(CloudAudioUsage)
}

/// The cloud side of Spatial audio.
public protocol SpatialLibrary: Sendable {
    /// The settings in force: called once at launch and after every change. The library follows `cloud`,
    /// `prepareAhead`, the profile the background queue prepares, the storage budget and the caps (library jobs have
    /// their own monthly sum and cap, apart from Sing's).
    func apply(_ settings: CloudAudioSettings) async

    /// Step 1 of spec 6.2: the verified local render, or nil. Called whenever the player builds an item, so it
    /// answers from memory: no network, no hashing, no directory scan.
    func localRendition(_ key: RenditionKey) async -> LocalRendition?

    /// Every local render of a song (Developer mode's per-song diagnostics read their manifests).
    func localRenditions(videoId: String) async -> [LocalRendition]

    /// The cloud's side of spec 6.1's state for one rendition: `ready` while a verified render is in the local store
    /// (whatever the switches say), `queued`, `waitingForNetwork` or `capReached` while it is wanted and not on a GPU
    /// yet, `processing`, `downloading`, `failed`, and `none` for anything not wanted or not under way. Never
    /// `preview`: that is the player's fact (`RenditionStatus.shown(onDeviceAudible:)`).
    func status(_ key: RenditionKey) async -> RenditionStatus

    /// Spec 6.2 for one rendition: the local store, else the shared library, else a job, as the two switches, the
    /// network and the caps allow. Both switches must be on for anything to leave or reach the phone: Cloud Studio's
    /// own "Process songs in the cloud" (the master, which the library reads itself) and `spatial.cloud`; with either
    /// off nothing happens, and the answer is `ready` for a render that is already in the local store (step 1 needs
    /// no cloud) and `none` otherwise. A render that is wanted but cannot start yet stays queued with its reason
    /// (`waitingForNetwork`, `capReached`) and starts when it can. Asking again for the same rendition while one is
    /// on its way, ready, or waiting out a failure's backoff changes nothing. Returns the status now; later ones come
    /// through `events()`.
    @discardableResult
    func request(_ request: RenditionRequest) async -> RenditionStatus

    /// The rendition was played just now (the local store removes the least recently played first).
    func markPlayed(_ key: RenditionKey) async

    func usage() async -> CloudAudioUsage

    /// "Remove downloaded renders": deletes every local render (never anything in the shared library) and returns
    /// what is left.
    @discardableResult
    func removeAll() async -> CloudAudioUsage

    func events() async -> AsyncStream<SpatialLibraryEvent>
}

// MARK: - The engine side

/// What is audible for the current song.
public enum SpatialAudible: Sendable, Hashable {
    /// Plain stereo: the stream or the downloaded file.
    case stereo
    /// The on-device stage, on top of the stream.
    case onDevice(SpatialProfile)
    /// A spatial cloud render, with the on-device stage bypassed.
    case render(SpatialProfile)

    /// The profile that is heard, if any.
    public var profile: SpatialProfile? {
        switch self {
        case .stereo: nil
        case .onDevice(let profile), .render(let profile): profile
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

/// Why a selected profile is not audible (spec 6.3 "Spatial active", 7): the Android app's `SpatialBlock`, with the
/// same four cases in the same order of precedence (when more than one holds, the first counts).
public enum SpatialBlock: Sendable, Hashable, CaseIterable {
    /// The route rule fails (6.1, 6.3): `spatial.route` is `headphones` and the sound goes somewhere else, the phone's
    /// speaker, a car, AirPlay, or another device that plays the music itself (Spotify Connect). 6.5: "Headphones
    /// only. Plug in to hear it."
    case route
    /// Sing's instrumental mode is on (6.3 "Spatial active"). 6.5: "Paused while Sing is on."
    case sing
    /// Another device plays the music itself (Spotify Connect) and the route rule did not already say no
    /// (`spatial.route` is `always`): such a device gets the normal sound whatever the mode (spec 1). 6.5 has no line
    /// for it, so the sheet shows none.
    case remote
    /// The song's sample rate is not one the on-device stage takes (6.3, 7: anything but 44.1 or 48 kHz) and no render
    /// plays. Its render is still wanted (`wantedRender`). No line of its own (6.3): the sheet shows none until the
    /// render plays.
    case format
}

/// The player's side of Spatial audio at one moment. Never the position.
public struct SpatialPlaybackSnapshot: Sendable, Hashable {
    /// The current queue entry's song (nil: nothing is loaded).
    public var songId: String?
    /// The YouTube video its audio comes from, when it has one.
    public var videoId: String?
    /// The selection the player was given.
    public var selection: SpatialSelection
    /// The route mode the player was given (`spatial.route`).
    public var route: SpatialRouteMode
    /// Where the audio goes now.
    public var output: SpatialOutputKind
    /// The route rule's answer for `output` and `route` (`SpatialActivation.routePasses`).
    public var routePasses: Bool
    /// Sing's instrumental plays (Spatial audio stands aside for it).
    public var singInstrumentalOn: Bool
    /// What is heard. While Spatial audio is active this is `onDevice` or `render`, except for a song at a sample
    /// rate the on-device stage does not take (not 44.1 or 48 kHz): that one plays `stereo` until its render is here.
    public var audible: SpatialAudible

    public init(songId: String? = nil, videoId: String? = nil, selection: SpatialSelection = .off,
                route: SpatialRouteMode = .headphones, output: SpatialOutputKind = .phoneSpeaker,
                routePasses: Bool = false, singInstrumentalOn: Bool = false, audible: SpatialAudible = .stereo) {
        self.songId = songId
        self.videoId = videoId
        self.selection = selection
        self.route = route
        self.output = output
        self.routePasses = routePasses
        self.singInstrumentalOn = singInstrumentalOn
        self.audible = audible
    }

    /// Nothing loaded, Spatial audio off.
    public static let idle = SpatialPlaybackSnapshot()

    /// "Spatial active" (spec 6.3).
    public var isActive: Bool { selection.isOn && routePasses && !singInstrumentalOn }

    /// Why the selected profile is not audible now, or nil when it is, when none is selected or nothing is loaded:
    /// the first of `route`, `sing`, `remote`, `format` that holds (the order the Android player reports them in).
    public var blockedBy: SpatialBlock? {
        guard selection.isOn, songId != nil else { return nil }
        // A device that plays the music itself never passes the route rule here; with `always` that is not the
        // rule saying no, it is the device (Android reports it the same way).
        let elsewhere = output == .remote && route == .always
        if !routePasses && !elsewhere { return .route }
        if singInstrumentalOn { return .sing }
        if elsewhere { return .remote }
        if audible == .stereo { return .format }
        return nil
    }

    /// The rendition the cloud should be asked for while this plays: the selected profile's render of this video,
    /// when Spatial audio is active and that render is not already what plays. Nil otherwise.
    public var wantedRender: RenditionKey? {
        guard isActive, let profile = selection.profile, let videoId, audible != .render(profile) else { return nil }
        return RenditionKey(videoId: videoId, profile: profile)
    }
}

/// The engine side of Spatial audio.
public protocol SpatialPlayback: Sendable {
    /// The settings in force: called once at launch and after every change. The player follows `profile` (at once,
    /// with a short ramp) and `route`.
    func apply(_ settings: CloudAudioSettings) async

    /// What plays now.
    func snapshot() async -> SpatialPlaybackSnapshot

    /// Every later snapshot: sent when the song, the selection, the output, Sing's mode or what is audible changes.
    func events() async -> AsyncStream<SpatialPlaybackSnapshot>
}

// MARK: - The line under the profile list

/// The status line of the Spatial audio sheet for the playing song (spec 6.5: "Every state has one"): one case per row
/// of the spec's table, each quoting its row. The Android app's `SpatialStatusLine` has the same ten cases in the same
/// order, and its strings are these sentences word for word.
public enum SpatialStatusLine: Sendable, Hashable, CaseIterable {
    /// Nothing to say: Spatial audio is off, nothing is loaded, or a state 6.5 has no row for (another device plays the
    /// music while `spatial.route` is `always`, or the song's sample rate is one the on-device stage does not take).
    case none
    /// "On your phone for now. The cloud version takes about a minute." The on-device stage plays and the cloud render
    /// is wanted (queued, uploading, processing).
    case onPhoneForNow
    /// "On your phone for now. The cloud version waits for Wi-Fi." Wanted, but no network the person allows.
    case waitingForWifi
    /// "On your phone only. This month's cloud limit is reached." Wanted, but the month's limit is reached.
    case cloudLimitReached
    /// "Getting the cloud version." The render is downloading, or is on the phone and the switch to it comes next.
    case gettingCloudVersion
    /// "Playing the cloud version."
    case cloudVersion
    /// "On your phone only. Turn on cloud renders for the full version." A profile is on, cloud renders are off.
    case onPhoneOnly
    /// "The cloud version didn't work this time. Still playing on your phone."
    case cloudFailed
    /// "Headphones only. Plug in to hear it." The route rule fails.
    case headphonesOnly
    /// "Paused while Sing is on." Sing's instrumental mode is on.
    case pausedForSing

    /// The spec's sentence (the English source text); nil only for `none`.
    public var text: String? {
        switch self {
        case .none: nil
        case .onPhoneForNow: "On your phone for now. The cloud version takes about a minute."
        case .waitingForWifi: "On your phone for now. The cloud version waits for Wi-Fi."
        case .cloudLimitReached: "On your phone only. This month's cloud limit is reached."
        case .gettingCloudVersion: "Getting the cloud version."
        case .cloudVersion: "Playing the cloud version."
        case .onPhoneOnly: "On your phone only. Turn on cloud renders for the full version."
        case .cloudFailed: "The cloud version didn't work this time. Still playing on your phone."
        case .headphonesOnly: "Headphones only. Plug in to hear it."
        case .pausedForSing: "Paused while Sing is on."
        }
    }

    /// The line for the playing song (6.5), from the settings, what the player does, the song's status for the
    /// selected profile as the person is told it (`RenditionStatus.shown(onDeviceAudible:)`) and whether cloud renders
    /// can happen at all (`cloudRendersOn`: Cloud Studio's "Process songs in the cloud", the master, and
    /// `spatial.cloud`, 6.1 "Two switches"). The same rules, in the same order, as the Android app's
    /// `SpatialStatusLine.of`:
    /// - no profile selected, or nothing loaded: `none`;
    /// - the route rule fails: `headphonesOnly`; else Sing's instrumental mode is on: `pausedForSing`;
    /// - a cloud render is audible: `cloudVersion`;
    /// - the on-device stage is audible: `onPhoneOnly` while cloud renders are off; else `cloudFailed` after a
    ///   failure, `waitingForWifi` and `cloudLimitReached` while the render is queued for that reason,
    ///   `gettingCloudVersion` while it comes down (or is already here and the switch to it is next), and
    ///   `onPhoneForNow` in every other case;
    /// - anything else (stereo: another device while `spatial.route` is `always`, or a rate the stage does not take):
    ///   `none`.
    public static func of(settings: CloudAudioSettings, snapshot: SpatialPlaybackSnapshot, status: RenditionStatus,
                          cloudRendersOn: Bool) -> SpatialStatusLine {
        guard settings.profile.isOn, snapshot.songId != nil else { return .none }
        switch snapshot.blockedBy {
        case .route?: return .headphonesOnly
        case .sing?: return .pausedForSing
        case .remote?, .format?, nil: break
        }
        if snapshot.audible.isCloudRender { return .cloudVersion }
        guard snapshot.audible.isOnDevice else { return .none }
        guard cloudRendersOn else { return .onPhoneOnly }
        switch status {
        case .failed: return .cloudFailed
        case .waitingForNetwork: return .waitingForWifi
        case .capReached: return .cloudLimitReached
        case .downloading, .ready: return .gettingCloudVersion
        case .none, .preview, .queued, .processing: return .onPhoneForNow
        }
    }
}

/// The other fixed sentence of the Spatial audio sheet (spec 6.5; the English source text).
public enum SpatialCopy {
    /// The quiet line under the profile list: why Spatial audio plays a little under stereo (spec 6.3 "Level").
    public static let levelNote = "Spatial plays a little quieter so the peaks stay clean."
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
    public func status(_ key: RenditionKey) async -> RenditionStatus { RenditionStatus.none }
    @discardableResult
    public func request(_ request: RenditionRequest) async -> RenditionStatus { RenditionStatus.none }
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
