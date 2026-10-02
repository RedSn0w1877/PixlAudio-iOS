import AVFoundation
import CoreMedia
import Foundation
import PixlAudioCore
import PixlModel

/// Stage 14: switching the current song between its own audio and a rendered instrumental, in sync, through the idle
/// deck — the dual-deck counterpart of Android's `InstrumentalCrossfadeController` shadow player. The other audio is
/// loaded on the idle deck at a point just ahead of the playhead, prerolled, and started on the host clock at the
/// exact moment the playing deck reaches that point; both taps then run a 700 ms linear crossfade from their own media
/// times and the decks swap. The queue entry stays the same, so the queue, Now Playing and lyrics never notice.
extension DualDeckEngine {
    /// Android `DEFAULT_CROSSFADE_MS`.
    static let instrumentalCrossfadeMs = 700
    /// How far ahead of the playhead the switch lands (covers loading + preroll).
    private static let switchLeadSeconds = 0.5

    /// Plays `url` (an instrumental) for the current entry, or its own audio again when `url` is nil. Returns false
    /// when nothing is loaded or the other audio can't be opened.
    @discardableResult
    func switchCurrentAudio(to url: URL?) async -> Bool {
        guard let outgoing = activeItem else { return false }
        finishFadeNow()
        cancelCrossfadePlan()
        let incoming: DeckItem
        do {
            incoming = try await factory.makeItem(for: outgoing.entry, overrideURL: url)
        } catch {
            return false
        }
        guard activeItem === outgoing, fade == nil else {
            factory.discard(incoming)
            return false
        }
        prepareReplayGain(incoming)
        let deck = idle
        var target = outgoing.positionSeconds + Self.switchLeadSeconds * Double(rate)
        deck.load(incoming, at: target)
        guard await waitUntilReady(incoming, on: deck, while: outgoing) else {
            deck.remove(incoming)
            factory.discard(incoming)
            return false
        }

        if !playWhenReady {
            // Paused: a silent swap at the current position.
            deck.seek(to: outgoing.positionSeconds)
            let previous = active
            active = deck
            activeItem = incoming
            discard(previous.removeAll())
            onTimingChanged?()
            scheduleNext()
            return true
        }

        // Preroll, then start exactly when the playing deck reaches `target`.
        var remaining = 0.0
        for _ in 0..<3 {
            _ = await deck.preroll(rate: rate)
            guard activeItem === outgoing, playWhenReady else {
                deck.remove(incoming)
                factory.discard(incoming)
                return false
            }
            remaining = (target - outgoing.positionSeconds) / Double(max(rate, 0.1))
            if remaining > 0.03 { break }
            target = outgoing.positionSeconds + Self.switchLeadSeconds * Double(rate)
            deck.seek(to: target)
            _ = await waitUntilReady(incoming, on: deck, while: outgoing)
        }
        guard remaining > 0.03 else {
            deck.remove(incoming)
            factory.discard(incoming)
            return false
        }
        let seconds = Double(Self.instrumentalCrossfadeMs) / 1000
        // The outgoing tap renders ahead of the playhead: its curve starts where its processing is, never in the past.
        let outgoingStart = max(target, outgoing.tap.processedMediaTime.load())
        incoming.tap.ramp.publish(CrossfadeRamp(role: .incoming, curve: .linear, startTime: target, duration: seconds, scale: 1))
        outgoing.tap.ramp.publish(CrossfadeRamp(role: .outgoing, curve: .linear, startTime: outgoingStart, duration: seconds,
                                                scale: 1))
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        deck.start(rate: rate, at: target, atHostTime: CMTimeAdd(hostNow, CMTime(seconds: remaining,
                                                                                preferredTimescale: 1_000_000_000)))
        fade = FadeRun(deck: active, item: outgoing, endMediaTime: outgoingStart + seconds)
        active = deck
        activeItem = incoming
        startFadeMonitor()
        onTimingChanged?()
        scheduleNext()
        return true
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
