// Which audio a song plays from while Spatial audio is on, and when the player switches between them (cloud audio spec
// of 2026-11-10, section 6.3). Pure: the app's player feeds it what it knows and does what it answers.

import Foundation
import PixlModel

/// What a player item plays, as Spatial audio sees it.
public enum SpatialItemAudio: Sendable, Hashable {
    /// The song's own audio (the stream, its cached file or its download) of a video (nil: not a YouTube video, or not
    /// known). The on-device stage may run on it.
    case own(videoId: String?)
    /// A spatial cloud render of the song: the on-device stage never runs on it (never spatialize twice).
    case render(RenditionKey)
    /// Other audio for the same queue entry (Sing's instrumental or its preview piece): never spatialized.
    case other

    /// The YouTube video the audio belongs to, when known.
    public var videoId: String? {
        switch self {
        case .own(let videoId): videoId
        case .render(let key): key.videoId
        case .other: nil
        }
    }

    public var isRender: Bool {
        if case .render = self { return true }
        return false
    }
}

public enum SpatialRenditionRules {
    /// A render that lands while its song plays is switched in only with at least this much of the song left (spec 6.3);
    /// otherwise the next play uses it.
    public static let minimumSecondsLeft: Double = 20
    /// The crossfade of a switch between renditions: short and linear (Sing's own swap keeps its 300–700 ms).
    public static let switchFadeSeconds: Double = 0.25
    /// How far apart the song's and a render's lengths may be for the switch to line them up (the Sing swap's own
    /// tolerance). A render that is further off plays from the next play on instead (it is not a failure).
    public static let alignmentToleranceSeconds: Double = 0.05

    // MARK: The start of a song

    /// Spec 6.3: at the start of a song, its local render of the selected profile plays instead of its own audio when
    /// a profile is selected and the route rule passes. Sing's instrumental mode is not asked here: a song always
    /// starts on its own audio, and when Sing brings the vocals back "its own audio" is the render again.
    public static func startsWithRender(selection: SpatialSelection, routePasses: Bool, hasLocalRender: Bool) -> Bool {
        selection.isOn && routePasses && hasLocalRender
    }

    // MARK: Switching while a song plays

    /// What the player knows when it asks whether to switch.
    public struct Situation: Sendable, Hashable {
        /// What the current item plays.
        public var playing: SpatialItemAudio
        public var selection: SpatialSelection
        /// The route rule's answer now (`SpatialActivation.routePasses`).
        public var routePasses: Bool
        /// Sing's instrumental plays, or Sing is in the middle of a switch of its own.
        public var singBusy: Bool
        /// A verified local render of the selected profile exists for the video that plays.
        public var hasLocalRender: Bool
        /// Seconds of the song left after the playhead (media time).
        public var secondsLeft: Double
        /// A seek, a song-to-song transition or another switch is under way: ask again once it is over.
        public var transitionInFlight: Bool

        public init(playing: SpatialItemAudio, selection: SpatialSelection, routePasses: Bool, singBusy: Bool = false,
                    hasLocalRender: Bool = false, secondsLeft: Double, transitionInFlight: Bool = false) {
            self.playing = playing
            self.selection = selection
            self.routePasses = routePasses
            self.singBusy = singBusy
            self.hasLocalRender = hasLocalRender
            self.secondsLeft = secondsLeft
            self.transitionInFlight = transitionInFlight
        }
    }

    public enum Action: Sendable, Hashable {
        /// Nothing to switch.
        case none
        /// Wait: something is under way (a seek, a transition, Sing's switch). Ask again when it is over.
        case wait
        /// Switch to the local render of this profile (same song, lined up by media time).
        case switchToRender(SpatialProfile)
        /// Switch back to the song's own audio (with the on-device stage when Spatial audio is active).
        case switchToOwnAudio
    }

    /// Spec 6.3, for the song that plays:
    /// - a render arrives (or is on the phone) for the selected profile while the song's own audio plays, Spatial audio
    ///   is active and at least `minimumSecondsLeft` remain: switch to it; with less, the next play uses it;
    /// - a render plays and Spatial audio is turned off or the route rule fails: back to the song's own audio;
    /// - a render plays and another profile is picked: that profile's local render when there is one, else back to the
    ///   song's own audio (the on-device stage then plays the new profile);
    /// - nothing switches while Sing's instrumental plays or Sing switches, and nothing while a seek or a transition is
    ///   under way (`wait`).
    public static func action(for situation: Situation) -> Action {
        switch situation.playing {
        case .other:
            return .none
        case .render(let key):
            let active = situation.selection.isOn && situation.routePasses
            let wanted: Action
            if !active {
                wanted = .switchToOwnAudio
            } else if let profile = situation.selection.profile, profile != key.profile {
                wanted = situation.hasLocalRender ? .switchToRender(profile) : .switchToOwnAudio
            } else {
                return .none
            }
            return situation.singBusy || situation.transitionInFlight ? .wait : wanted
        case .own(let videoId):
            guard videoId != nil, let profile = situation.selection.profile, situation.routePasses,
                  situation.hasLocalRender else { return .none }
            guard situation.secondsLeft >= minimumSecondsLeft else { return .none }
            return situation.singBusy || situation.transitionInFlight ? .wait : .switchToRender(profile)
        }
    }

    /// The 20 s rule at the moment the switch would start (`startSeconds`, media time) for a song of `durationSeconds`.
    public static func leavesEnough(durationSeconds: Double, startSeconds: Double,
                                    minimum: Double = minimumSecondsLeft) -> Bool {
        durationSeconds - startSeconds >= minimum
    }

    // MARK: Lining up by media time

    /// The frame at `seconds` in audio at `sampleRate` (the frame that sample time falls in).
    public static func frame(atSeconds seconds: Double, sampleRate: Int) -> Int64 {
        Int64((max(seconds, 0) * Double(sampleRate)).rounded(.down))
    }

    /// The media time of `frame` in audio at `sampleRate`.
    public static func seconds(atFrame frame: Int64, sampleRate: Int) -> Double {
        Double(frame) / Double(max(sampleRate, 1))
    }

    /// The frame of another file that sounds at the same media time as `frame` of this one: a render can have another
    /// rate than the stream (44.1 kHz from an iPhone's upload, the stream's own rate from Android's), so files are
    /// lined up by time, never by frame count.
    public static func alignedFrame(_ frame: Int64, sampleRate: Int, inSampleRate other: Int) -> Int64 {
        Int64((Double(frame) * Double(other) / Double(max(sampleRate, 1))).rounded())
    }

    /// Whether a render lines up with the song: their lengths in seconds within `tolerance` (frame counts differ
    /// between rates and are never compared).
    public static func lengthsAlign(songSeconds: Double, renderSeconds: Double,
                                    tolerance: Double = alignmentToleranceSeconds) -> Bool {
        abs(songSeconds - renderSeconds) <= tolerance
    }

    // MARK: The video of a file

    /// The video id of the song's own audio file from its path: `…/Downloads/<videoId>.<ext>` (a download),
    /// `…/streams/<videoId>.<ext>` (the stream cache's complete file) or `…/opus/<videoId>.mp4` (the repackaged Opus
    /// file, `OpusStreams`); nil for any other file. A render file is not its song's own audio
    /// (`CloudAudioLocalLayout.rendition(ofAudioFileAt:)` names it).
    public static func ownAudioVideoId(pathComponents: [String]) -> String? {
        guard pathComponents.count >= 2 else { return nil }
        let folder = pathComponents[pathComponents.count - 2]
        guard folder == "Downloads" || folder == "streams" || folder == "opus" else { return nil }
        let name = pathComponents[pathComponents.count - 1]
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
        let id = String(name[..<dot])
        return CloudLibrary.isValidVideoId(id) ? id : nil
    }
}
