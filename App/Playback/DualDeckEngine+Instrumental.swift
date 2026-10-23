import AVFoundation
import CoreMedia
import Foundation
import PixlAudioCore
import PixlModel

/// Stage 14: switching the current song between its own audio and a rendered instrumental, in sync, through the idle
/// deck — the dual-deck counterpart of Android's `InstrumentalCrossfadeController` shadow player. The other audio is
/// loaded on the idle deck at a point just ahead of the playhead, prerolled, and started on the host clock at the
/// exact moment the playing deck reaches that point; both taps then run a linear crossfade from their own media
/// times (700 ms, or whatever the caller's placement asks for) and the decks swap. The queue entry stays the same, so
/// the queue, Now Playing and lyrics never notice.
///
/// A caller can place the swap (`SwitchPlacement`): Sing starts it at the next quiet moment between sung words, with a
/// fade that fits the gap. A seek while the other audio loads, a song-to-song transition about to begin, or an
/// instrumental that is not the same length as the song ends the attempt instead of playing it out of place.
extension DualDeckEngine {
    /// How a `switchCurrentAudio` ended.
    nonisolated enum SwitchOutcome: Equatable, Sendable {
        /// The other audio plays now (or, paused, will when playback resumes).
        case switched
        /// Nothing was loaded, the other audio could not be opened, playback paused or moved on, or a transition of the
        /// song's own was too close.
        case failed
        /// The playhead was moved (a seek) while the switch was being prepared, so its place no longer holds.
        case abortedBySeek
        /// `requireAligned`: the other audio is not the same length as the song, so it would not line up.
        case misaligned
    }

    /// Where the swap starts, asked once the other audio is loaded and the earliest start is known: gets that earliest
    /// media second of the current audio and answers the second to start at (never before it) and the fade length in
    /// seconds (clamped to 0.3…0.7).
    typealias SwitchPlacement = @MainActor (_ earliestSeconds: Double) -> (startSeconds: Double, fadeSeconds: Double)

    /// Android `DEFAULT_CROSSFADE_MS`; also the longest fade a placement may ask for.
    static let instrumentalCrossfadeMs = 700
    /// The shortest fade a placement may ask for (a word gap can be that short).
    static let instrumentalMinCrossfadeMs = 300
    /// How far apart the song's and the other audio's lengths may be for `requireAligned` (seconds).
    static let instrumentalAlignmentToleranceSeconds = 0.05
    /// How far ahead of the playhead the switch lands (covers loading + preroll).
    private static let switchLeadSeconds = 0.5
    /// The earliest start offered to a placement, ahead of the playhead. Never under 0.4 s: the outgoing tap renders
    /// ahead of the playhead, and a start closer than that would begin its fade where the tap already is, not at the
    /// start the incoming fade uses.
    private static let placedLeadSeconds = 0.45
    /// A switch that would end this close (seconds) before the song's own planned transition is not made.
    private static let switchClearanceSeconds = 1.0
    /// A playhead that went back further than this since the switch began was moved.
    private static let backwardSeekSeconds = 0.25

    /// Plays `url` (an instrumental) for the current entry, or its own audio again when `url` is nil. Returns false
    /// when nothing is loaded or the other audio can't be opened.
    @discardableResult
    func switchCurrentAudio(to url: URL?) async -> Bool {
        await switchCurrentAudio(to: url, placement: nil, requireAligned: false) == .switched
    }

    /// `switchCurrentAudio(to:)`, with the swap placed by `placement` (nil: as soon as the other audio is ready) and
    /// the outcome told. With `requireAligned` the other audio must be as long as the song (within 50 ms) or nothing is
    /// switched. Whatever the outcome other than `.switched`, the song plays on and its own plan for what comes next
    /// is made again.
    func switchCurrentAudio(to url: URL?, placement: SwitchPlacement?, requireAligned: Bool = false) async -> SwitchOutcome {
        await switchAudio(to: .file(url), placement: placement, requireAligned: requireAligned)
    }

    /// Sing's preview piece: plays `url` — a stretch of the instrumental that starts `offsetSeconds` into the song — in
    /// place of the current audio, at the same position (the clip's own time is the song's minus the offset). The clip
    /// goes on the idle deck inside a composition as long as the song (`DeckItemFactory.makeClipItem`), so the placed
    /// crossfade, seeks, the lyrics clock and the way back work as for a whole instrumental. Outside the clip that item
    /// is silent: the caller goes back before the clip runs out, or as soon as a seek leaves it.
    func switchCurrentAudio(toClip url: URL, offsetSeconds: Double, placement: SwitchPlacement?) async -> SwitchOutcome {
        await switchAudio(to: .clip(url, offsetSeconds: offsetSeconds), placement: placement, requireAligned: false)
    }

    /// What a switch plays.
    private enum SwitchSource {
        /// A whole file for the entry (an instrumental), or its own audio when nil.
        case file(URL?)
        /// A preview piece starting this far into the song.
        case clip(URL, offsetSeconds: Double)
    }

    private func switchAudio(to source: SwitchSource, placement: SwitchPlacement?, requireAligned: Bool) async
        -> SwitchOutcome {
        guard let outgoing = activeItem else { return .failed }
        let seekGeneration = outgoing.seekGeneration
        let startedAt = outgoing.positionSeconds
        // The song's own transition (a crossfade, or the gapless hand-over at the end) is cancelled below; where it
        // was planned tells whether a swap fits before it.
        let plannedPointMs = plannedTransition?.transitionPointMs
        let defaultFadeSeconds = Double(Self.instrumentalCrossfadeMs) / 1000
        func transitionTooClose(start: Double, fade: Double) -> Bool {
            guard let plannedPointMs else { return false }
            return Double(plannedPointMs) / 1000 < start + fade + Self.switchClearanceSeconds
        }
        if transitionTooClose(start: startedAt + Self.switchLeadSeconds * Double(rate), fade: defaultFadeSeconds) {
            return .failed
        }
        finishFadeNow()
        cancelCrossfadePlan()

        /// Every way out but the swap: the other audio is dropped and the plan that was cancelled is made again.
        func leave(_ outcome: SwitchOutcome, _ incoming: DeckItem? = nil, on deck: Deck? = nil) -> SwitchOutcome {
            if let incoming {
                deck?.remove(incoming)
                factory.discard(incoming)
            }
            if activeItem === outgoing { scheduleNext() }
            return outcome
        }
        /// A seek since the switch began, or the playhead going back: the place it was planned for is gone.
        func playheadMoved() -> Bool {
            outgoing.seekGeneration != seekGeneration || outgoing.positionSeconds < startedAt - Self.backwardSeekSeconds
        }
        func clampedFade(_ seconds: Double) -> Double {
            Swift.min(Swift.max(seconds, Double(Self.instrumentalMinCrossfadeMs) / 1000), defaultFadeSeconds)
        }

        let incoming: DeckItem
        do {
            switch source {
            case .file(let url):
                incoming = try await factory.makeItem(for: outgoing.entry, overrideURL: url)
            case .clip(let url, let offsetSeconds):
                incoming = try await factory.makeClipItem(for: outgoing.entry, clipURL: url, offsetSeconds: offsetSeconds,
                                                          songSeconds: outgoing.durationSeconds)
            }
        } catch {
            return leave(.failed)
        }
        guard activeItem === outgoing, fade == nil else {
            factory.discard(incoming)
            return .failed
        }
        if playheadMoved() { return leave(.abortedBySeek, incoming) }
        if requireAligned,
           abs(incoming.durationSeconds - outgoing.durationSeconds) > Self.instrumentalAlignmentToleranceSeconds {
            return leave(.misaligned, incoming)
        }
        prepareReplayGain(incoming)
        let deck = idle
        var target = outgoing.positionSeconds + Self.switchLeadSeconds * Double(rate)
        deck.load(incoming, at: target)
        guard await waitUntilReady(incoming, on: deck, while: outgoing) else { return leave(.failed, incoming, on: deck) }
        if playheadMoved() { return leave(.abortedBySeek, incoming, on: deck) }

        if !playWhenReady {
            // Paused: a silent swap at the current position.
            deck.seek(to: outgoing.positionSeconds)
            let previous = active
            active = deck
            activeItem = incoming
            discard(previous.removeAll())
            onTimingChanged?()
            scheduleNext()
            return .switched
        }

        // Where the swap starts: ahead of the playhead by what loading and preroll need, and where the placement says.
        var fadeSeconds = defaultFadeSeconds
        var replans = 0
        if let placement {
            let earliest = outgoing.positionSeconds + Self.placedLeadSeconds * Double(rate)
            let placed = placement(earliest)
            let planned = Swift.max(placed.startSeconds, earliest)
            fadeSeconds = clampedFade(placed.fadeSeconds)
            if abs(planned - target) > 0.02 {
                target = planned
                deck.seek(to: target)
                guard await waitUntilReady(incoming, on: deck, while: outgoing) else {
                    return leave(.failed, incoming, on: deck)
                }
                if playheadMoved() { return leave(.abortedBySeek, incoming, on: deck) }
            }
        }
        if transitionTooClose(start: target, fade: fadeSeconds) { return leave(.failed, incoming, on: deck) }

        // Preroll, then start exactly when the playing deck reaches `target`.
        var remaining = 0.0
        for _ in 0..<3 {
            _ = await deck.preroll(rate: rate)
            guard activeItem === outgoing, playWhenReady else { return leave(.failed, incoming, on: deck) }
            if playheadMoved() { return leave(.abortedBySeek, incoming, on: deck) }
            remaining = (target - outgoing.positionSeconds) / Double(max(rate, 0.1))
            if remaining > 0.03 { break }
            // The playhead passed the start while the other audio was loading: choose again (a placement a couple of
            // times, so a word gap is still looked for), then simply as soon as possible.
            let soonest = outgoing.positionSeconds + Self.switchLeadSeconds * Double(rate)
            if let placement, replans < 2 {
                replans += 1
                let placed = placement(outgoing.positionSeconds + Self.placedLeadSeconds * Double(rate))
                target = Swift.max(placed.startSeconds, soonest)
                fadeSeconds = clampedFade(placed.fadeSeconds)
            } else {
                target = soonest
            }
            deck.seek(to: target)
            _ = await waitUntilReady(incoming, on: deck, while: outgoing)
            if transitionTooClose(start: target, fade: fadeSeconds) { return leave(.failed, incoming, on: deck) }
        }
        guard remaining > 0.03 else { return leave(.failed, incoming, on: deck) }
        // The outgoing tap renders ahead of the playhead: its curve starts where its processing is, never in the past.
        let outgoingStart = max(target, outgoing.tap.processedMediaTime.load())
        incoming.tap.ramp.publish(CrossfadeRamp(role: .incoming, curve: .linear, startTime: target, duration: fadeSeconds,
                                                scale: 1))
        outgoing.tap.ramp.publish(CrossfadeRamp(role: .outgoing, curve: .linear, startTime: outgoingStart,
                                                duration: fadeSeconds, scale: 1))
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        deck.start(rate: rate, at: target, atHostTime: CMTimeAdd(hostNow, CMTime(seconds: remaining,
                                                                                preferredTimescale: 1_000_000_000)))
        fade = FadeRun(deck: active, item: outgoing, endMediaTime: outgoingStart + fadeSeconds)
        active = deck
        activeItem = incoming
        startFadeMonitor()
        onTimingChanged?()
        scheduleNext()
        return .switched
    }

    /// Waits (≤ 5 s) until `item` is ready on `deck` with its seek applied, while `outgoing` is still current.
    private func waitUntilReady(_ item: DeckItem, on deck: Deck, while outgoing: DeckItem) async -> Bool {
        var waited = 0
        while waited < 5000 {
            if activeItem !== outgoing || item.playerItem.status == .failed { return false }
            if deck.isReadyToPreroll(item), item.pendingSeekSeconds == nil, item.seekTargetSeconds == nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return false
    }
}
