import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// Which audio a song plays from with Spatial audio on, and when the player switches (cloud audio spec 6.3).
@Suite("Spatial renditions")
struct SpatialRenditionRulesTests {
    private static let video = "J7p4bzqLvCw"
    private static let studioRender = SpatialItemAudio.render(RenditionKey(videoId: video, profile: .studio))

    private func situation(_ playing: SpatialItemAudio, _ selection: SpatialSelection = .profile(.studio),
                           routePasses: Bool = true, singBusy: Bool = false, hasLocalRender: Bool = true,
                           secondsLeft: Double = 120, transitionInFlight: Bool = false) -> SpatialRenditionRules.Situation {
        SpatialRenditionRules.Situation(playing: playing, selection: selection, routePasses: routePasses,
                                        singBusy: singBusy, hasLocalRender: hasLocalRender, secondsLeft: secondsLeft,
                                        transitionInFlight: transitionInFlight)
    }

    @Test func aSongStartsOnItsRenderOnlyWhenAProfileIsOnTheRoutePassesAndTheRenderIsHere() {
        #expect(SpatialRenditionRules.startsWithRender(selection: .profile(.hall), routePasses: true, hasLocalRender: true))
        #expect(!SpatialRenditionRules.startsWithRender(selection: .off, routePasses: true, hasLocalRender: true))
        #expect(!SpatialRenditionRules.startsWithRender(selection: .profile(.hall), routePasses: false,
                                                        hasLocalRender: true))
        #expect(!SpatialRenditionRules.startsWithRender(selection: .profile(.hall), routePasses: true,
                                                        hasLocalRender: false))
    }

    @Test func aRenderThatLandsSwitchesInWithTwentySecondsLeft() {
        let own = SpatialItemAudio.own(videoId: Self.video)
        #expect(SpatialRenditionRules.action(for: situation(own)) == .switchToRender(.studio))
        #expect(SpatialRenditionRules.action(for: situation(own, secondsLeft: 20)) == .switchToRender(.studio))
        // Less than 20 s left: the next play uses it.
        #expect(SpatialRenditionRules.action(for: situation(own, secondsLeft: 19.9)) == .none)
        // A seek or a song change under way: wait and ask again; Sing busy: the same.
        #expect(SpatialRenditionRules.action(for: situation(own, transitionInFlight: true)) == .wait)
        #expect(SpatialRenditionRules.action(for: situation(own, singBusy: true)) == .wait)
        // No render, no profile, the route fails, or no video: nothing.
        #expect(SpatialRenditionRules.action(for: situation(own, hasLocalRender: false)) == .none)
        #expect(SpatialRenditionRules.action(for: situation(own, .off)) == .none)
        #expect(SpatialRenditionRules.action(for: situation(own, routePasses: false)) == .none)
        #expect(SpatialRenditionRules.action(for: situation(.own(videoId: nil))) == .none)
        // Sing's instrumental or its preview piece is never switched from here.
        #expect(SpatialRenditionRules.action(for: situation(.other)) == .none)
    }

    @Test func aPlayingRenderGoesBackToTheSongWhenSpatialStopsOrTheRouteFails() {
        let render = Self.studioRender
        #expect(SpatialRenditionRules.action(for: situation(render)) == .none)
        #expect(SpatialRenditionRules.action(for: situation(render, .off)) == .switchToOwnAudio)
        #expect(SpatialRenditionRules.action(for: situation(render, routePasses: false)) == .switchToOwnAudio)
        // The way back has no 20 s rule (the switch itself still keeps clear of the song's end).
        #expect(SpatialRenditionRules.action(for: situation(render, .off, secondsLeft: 5)) == .switchToOwnAudio)
        #expect(SpatialRenditionRules.action(for: situation(render, .off, transitionInFlight: true)) == .wait)
    }

    /// "This song" (Hoa, 2026-11-11): the player decides with the song's own selection
    /// (`CloudAudioSettings.selection(for:)`), `off` for a song turned off: it starts on its own audio, a render it
    /// plays goes back to its own audio (the same way back as Spatial audio switched off) and none switches in.
    @Test func aSongTurnedOffPlaysItsOwnAudio() {
        var settings = CloudAudioSettings(builtInCloudKeys: true)
        settings.profile = .profile(.studio)
        settings.songsOff = ["off-song"]
        let off = settings.selection(for: "off-song")
        #expect(!SpatialRenditionRules.startsWithRender(selection: off, routePasses: true, hasLocalRender: true))
        #expect(SpatialRenditionRules.action(for: situation(Self.studioRender, off)) == .switchToOwnAudio)
        #expect(SpatialRenditionRules.action(for: situation(Self.studioRender, off, secondsLeft: 5)) == .switchToOwnAudio)
        #expect(SpatialRenditionRules.action(for: situation(Self.studioRender, off, singBusy: true)) == .wait)
        #expect(SpatialRenditionRules.action(for: situation(.own(videoId: Self.video), off)) == .none)
        // Every other song keeps the profile.
        let other = settings.selection(for: "other-song")
        #expect(SpatialRenditionRules.startsWithRender(selection: other, routePasses: true, hasLocalRender: true))
        #expect(SpatialRenditionRules.action(for: situation(Self.studioRender, other)) == .none)
        #expect(SpatialRenditionRules.action(for: situation(.own(videoId: Self.video), other)) == .switchToRender(.studio))
    }

    @Test func anotherProfileSwapsToItsRenderOrBackToTheSong() {
        let render = Self.studioRender
        #expect(SpatialRenditionRules.action(for: situation(render, .profile(.hall), hasLocalRender: true))
                == .switchToRender(.hall))
        #expect(SpatialRenditionRules.action(for: situation(render, .profile(.hall), hasLocalRender: false))
                == .switchToOwnAudio)
        #expect(SpatialRenditionRules.action(for: situation(render, .profile(.hall), singBusy: true)) == .wait)
    }

    @Test func theTwentySecondRuleCountsMediaTimeFromWhereTheSwitchStarts() {
        #expect(SpatialRenditionRules.leavesEnough(durationSeconds: 200, startSeconds: 180))
        #expect(!SpatialRenditionRules.leavesEnough(durationSeconds: 200, startSeconds: 180.5))
        #expect(SpatialRenditionRules.minimumSecondsLeft == 20)
        #expect(SpatialRenditionRules.switchFadeSeconds == 0.25)
    }

    /// Spec 6.2: a render's rate is the uploaded file's, so a phone may play a 44.1 kHz render of a 48 kHz stream; the
    /// two are lined up by media time.
    @Test func filesAtDifferentRatesLineUpByMediaTime() {
        #expect(SpatialRenditionRules.frame(atSeconds: 1, sampleRate: 44_100) == 44_100)
        #expect(SpatialRenditionRules.frame(atSeconds: 1, sampleRate: 48_000) == 48_000)
        #expect(SpatialRenditionRules.seconds(atFrame: 96_000, sampleRate: 48_000) == 2)
        #expect(SpatialRenditionRules.alignedFrame(48_000, sampleRate: 48_000, inSampleRate: 44_100) == 44_100)
        #expect(SpatialRenditionRules.alignedFrame(44_100 * 90, sampleRate: 44_100, inSampleRate: 48_000) == 48_000 * 90)
        // Any frame lands within half a frame of the same time in the other file.
        for frame: Int64 in [0, 1, 7, 12_345, 4_410_000, 9_696_001] {
            let other = SpatialRenditionRules.alignedFrame(frame, sampleRate: 48_000, inSampleRate: 44_100)
            let a = SpatialRenditionRules.seconds(atFrame: frame, sampleRate: 48_000)
            let b = SpatialRenditionRules.seconds(atFrame: other, sampleRate: 44_100)
            #expect(abs(a - b) <= 0.5 / 44_100 + 1e-12)
        }
        // The same song: 202 s is 9 696 000 frames at 48 kHz and 8 908 200 at 44.1 kHz. The lengths are compared in
        // seconds, never in frames.
        let stream = SpatialRenditionRules.seconds(atFrame: 9_696_000, sampleRate: 48_000)
        let render = SpatialRenditionRules.seconds(atFrame: 8_908_200, sampleRate: 44_100)
        #expect(SpatialRenditionRules.lengthsAlign(songSeconds: stream, renderSeconds: render))
        #expect(!SpatialRenditionRules.lengthsAlign(songSeconds: stream, renderSeconds: render + 0.2))
    }

    @Test func theVideoOfASongsOwnFileComesFromItsFolderAndName() {
        let id = Self.video
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "var", "Application Support", "Downloads",
                                                                       "\(id).m4a"]) == id)
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "Caches", "YouTube", "streams",
                                                                       "\(id).m4a"]) == id)
        // The repackaged Opus file (`Library/Caches/YouTube/opus/<id>.mp4`) is the song's own audio too, so a song
        // playing from it still links to its cloud render.
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "Caches", "YouTube", "opus",
                                                                       "\(id).mp4"]) == id)
        // A render of the song is not its own audio; a file anywhere else is not a YouTube video.
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "CloudAudio", id, "sp-studio.flac"]) == nil)
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "Music", "my-track-01.m4a"]) == nil)
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["/", "Downloads", "not a video.m4a"]) == nil)
        #expect(SpatialRenditionRules.ownAudioVideoId(pathComponents: ["Downloads"]) == nil)
        #expect(SpatialItemAudio.own(videoId: id).videoId == id)
        #expect(Self.studioRender.videoId == id && Self.studioRender.isRender)
        #expect(SpatialItemAudio.other.videoId == nil)
    }
}
