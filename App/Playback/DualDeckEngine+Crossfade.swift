import CoreMedia
import Foundation
import PixlAudioCore
import PixlModel

/// What follows the current item: Android's overlap crossfade, or a gapless hand-over (mode NONE and every case
/// without a crossfade).
struct CrossfadePlan {
    let id: Int
    /// The item the plan was made for (a different current item invalidates it).
    let source: DeckItem
    let targetEntry: QueueEntry
    let settings: TransitionSettings
    let transitionPointMs: Int64
    let fadeMs: Int64
    /// A gapless hand-over: the incoming deck starts exactly at the source's last frame (no gain curves).
    var isHandOver = false
}

/// A running fade: the outgoing deck keeps playing until its gain curve reaches 0 (after a hand-over: until its item
/// ends).
struct FadeRun {
    let deck: Deck
    let item: DeckItem
    /// Media time of the outgoing item at which its curve ends.
    let endMediaTime: Double
}

/// A hand-over whose incoming deck is scheduled on the host clock.
struct ScheduledHandOver {
    let planId: Int
    let incoming: DeckItem
    let outgoing: DeckItem
    /// The deck holding `incoming` (the idle deck when it was scheduled).
    let deck: Deck
}

/// Android's overlap crossfade (`DualPlayerEngine.performOverlapTransition` + `TransitionController`), with the pure
/// decisions from PixlAudioCore's `TransitionRuleResolver` / `CrossfadeScheduler` and the gains applied inside each
/// item's processing tap (`CrossfadeRamp`, evaluated from the item's own media time). Every mode except NONE runs the
/// same overlap; FADE_IN_OUT, OVERLAP and SMOOTH differ through their curves (Android behaviour).
///
/// Gapless (NONE) is a hand-over between the two decks too: an item carrying a processing tap does not join the next
/// one gaplessly inside `AVQueuePlayer` (measured on CI: ~0.45–0.5 s of silence per join with a tap, none without —
/// `GaplessDiagnosticsTests`). So the next item is built and prerolled on the idle deck and started with
/// `setRate(_:time:atHostTime:)` at the host time of the current item's last frame; the decks swap at that moment.
extension DualDeckEngine {
    /// How long before the end a hand-over is scheduled on the host clock.
    static let handOverLeadMs: Int64 = 1000
    /// How long before the transition point the hand-over's incoming item is built and prerolled (streamed targets).
    static let handOverPrepareLeadMs: Int64 = 4500

    /// Whether a hand-over's incoming item is built as soon as the countdown's debounce has run instead of in the last
    /// `handOverPrepareLeadMs`: songs from the library's files (`f:` / `mp:`) read from the device, so parking the next
    /// one on the idle deck costs a few MB, no network, and a skip then takes the prepared item over at once. A
    /// streamed target keeps the late lead: a paused item on the idle deck would pull bytes the owner's data limits
    /// (Low Data Mode, cellular) decide on.
    static func preparesHandOverEarly(for target: Song) -> Bool { LibraryIdentity.isManaged(target.id) }

    /// The planned crossfade (nil when a gapless hand-over is planned instead).
    var plannedCrossfade: CrossfadePlan? {
        guard let plan = plannedTransition, !plan.isHandOver else { return nil }
        return plan
    }

    /// The planned gapless hand-over.
    var plannedHandOver: CrossfadePlan? {
        guard let plan = plannedTransition, plan.isHandOver else { return nil }
        return plan
    }

    /// The crossfade plan for `current`, or nil when it should hand over gaplessly (mode NONE, crossfade off
    /// globally, no next song, track too short, transitions suspended).
    func crossfadePlan(for current: DeckItem) -> CrossfadePlan? {
        guard !suspensions.isSuspended, let targetIndex = queue.crossfadeTargetIndex,
              let target = queue.entry(at: targetIndex), let from = queue.current else { return nil }
        let resolution = TransitionRuleResolver.resolve(playlistId: queuePlaylistId, fromTrackId: from.song.id,
                                                        toTrackId: target.song.id, rules: transitionRules,
                                                        global: globalTransition)
        let durationMs = Int64(current.durationSeconds * 1000)
        guard durationMs > 0,
              case let .crossfade(point, fadeMs) = CrossfadeScheduler.plan(resolution: resolution,
                                                                            crossfadeEnabled: crossfadeEnabled,
                                                                            trackDurationMs: durationMs)
        else { return nil }
        nextPlanId += 1
        return CrossfadePlan(id: nextPlanId, source: current, targetEntry: target, settings: resolution.settings,
                             transitionPointMs: point, fadeMs: fadeMs)
    }

    /// A gapless hand-over from `current` to `target` (the next entry for auto-advance).
    func handOverPlan(for current: DeckItem, target: QueueEntry) -> CrossfadePlan {
        nextPlanId += 1
        let durationMs = Int64(current.durationSeconds * 1000)
        return CrossfadePlan(id: nextPlanId, source: current, targetEntry: target,
                             settings: TransitionSettings(mode: .none),
                             transitionPointMs: max(durationMs - Self.handOverLeadMs, 0), fadeMs: 0, isHandOver: true)
    }

    func startCrossfade(_ plan: CrossfadePlan) {
        plannedTransition = plan
        guard playWhenReady else { return }   // the countdown starts on play
        runCountdown(plan, debounce: true)
    }

    /// Sleeps towards the transition point (speed-scaled, waking more often near it), prepares the incoming item on
    /// the idle deck (crossfade: after the debounce; hand-over: once within `handOverPrepareLeadMs`), then fires.
    private func runCountdown(_ plan: CrossfadePlan, debounce: Bool) {
        crossfadeTask?.cancel()
        cancelScheduledHandOver()
        let remainingAtStart = plan.transitionPointMs - currentPositionMs()
        let debounceMs = debounce ? min(CrossfadeScheduler.debounceMs, max(remainingAtStart / 2, 0)) : 0
        let prepareLeadMs = plan.isHandOver && Self.preparesHandOverEarly(for: plan.targetEntry.song)
            ? Int64.max : Self.handOverPrepareLeadMs
        crossfadeTask = Task { [weak self] in
            if debounceMs > 0 { try? await Task.sleep(for: .milliseconds(debounceMs)) }
            guard let self, !Task.isCancelled, self.plannedTransition?.id == plan.id else { return }
            if !plan.isHandOver { self.prepareIncoming(plan) }
            while !Task.isCancelled {
                let remaining = plan.transitionPointMs - self.currentPositionMs()
                if plan.isHandOver && remaining <= prepareLeadMs { self.prepareIncoming(plan) }
                if remaining <= 0 { break }
                var sleepMs = CrossfadeScheduler.countdownSleepMs(remainingMs: remaining, speed: self.rate)
                if plan.isHandOver && remaining > prepareLeadMs {
                    sleepMs = min(sleepMs, max(remaining - prepareLeadMs, 50))
                }
                try? await Task.sleep(for: .milliseconds(sleepMs))
            }
            guard !Task.isCancelled, self.plannedTransition?.id == plan.id else { return }
            if plan.isHandOver {
                await self.fireHandOver(plan)
            } else {
                await self.fire(plan)
            }
        }
    }

    /// Builds the incoming item and parks it, paused, on the idle deck (a crossfade's incoming curve starts at 0).
    private func prepareIncoming(_ plan: CrossfadePlan) {
        guard preparedIncoming == nil, preparingIncomingTask == nil else { return }
        // A fade still finishing on the idle deck ends now (only possible with very short tracks).
        finishFadeNow()
        preparingIncomingTask = Task { [weak self] in
            guard let self else { return }
            let item = try? await self.factory.makeItem(for: plan.targetEntry)
            self.preparingIncomingTask = nil
            guard let item else { return }
            guard !Task.isCancelled, self.plannedTransition?.id == plan.id, self.fade == nil else {
                self.factory.discard(item)
                return
            }
            if !plan.isHandOver {
                item.tap.ramp.publish(CrossfadeRamp(role: .incoming, curve: plan.settings.curveIn, startTime: 0,
                                                    duration: Double(max(plan.fadeMs, CrossfadeRun.minimumDurationMs)) / 1000,
                                                    scale: 1))
            }
            self.prepareReplayGain(item)
            self.idle.load(item, at: 0)
            self.preparedIncoming = item
        }
    }

    /// The final check at the transition point, then the overlap.
    private func fire(_ plan: CrossfadePlan) async {
        guard let outgoing = activeItem, outgoing === plan.source else { return }
        let decision = CrossfadeScheduler.fireDecision(trackDurationMs: Int64(outgoing.durationSeconds * 1000),
                                                       positionMs: currentPositionMs(), fadeDurationMs: plan.fadeMs)
        guard case .fire(let durationMs) = decision else {
            // Nothing left to fade: the item's end advances normally.
            cancelCrossfadePlan()
            return
        }
        var waited: Int64 = 0
        while preparedIncoming == nil && waited < CrossfadeScheduler.incomingReadyTimeoutMs {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 50
            if Task.isCancelled { return }
        }
        guard let incoming = preparedIncoming, activeItem === outgoing, plannedTransition?.id == plan.id else {
            cancelCrossfadePlan()
            return
        }
        perform(plan, incoming: incoming, outgoing: outgoing, durationMs: durationMs)
    }

    /// Starts the incoming deck, sets both gain curves and swaps the decks.
    private func perform(_ plan: CrossfadePlan, incoming: DeckItem, outgoing: DeckItem, durationMs: Int) {
        let settings = CrossfadeScheduler.firingSettings(plan.settings, durationMs: durationMs)
        let run = CrossfadeRun(settings: settings, outgoingStartVolume: 1)
        // The tap renders ahead of the playhead: start the outgoing curve where its processing currently is, so the
        // gain never jumps.
        let outgoingStart = max(outgoing.positionSeconds, outgoing.tap.processedMediaTime.load())
        let ramps = CrossfadeRamp.pair(run: run, outgoingStartTime: outgoingStart, incomingStartTime: 0,
                                       incomingTarget: 1)
        outgoing.tap.ramp.publish(ramps.outgoing)
        incoming.tap.ramp.publish(ramps.incoming)
        let fadeRun = FadeRun(deck: active, item: outgoing, endMediaTime: outgoingStart + Double(run.durationMs) / 1000)
        swapDecks(to: incoming, from: outgoing, fade: fadeRun, startIncoming: true)
    }

    /// Makes `incoming` (on the idle deck) current, leaves `outgoing` finishing as `fade`, and reports the change.
    private func swapDecks(to incoming: DeckItem, from outgoing: DeckItem, fade fadeRun: FadeRun, startIncoming: Bool) {
        active = idle
        preparedIncoming = nil
        plannedTransition = nil
        crossfadeTask = nil
        scheduledHandOver = nil
        activeItem = incoming
        fade = fadeRun
        if playWhenReady {
            if startIncoming { startActive() }
            startFadeMonitor()
        }

        if let index = queue.index(ofEntry: incoming.entry.id) {
            queue.setCurrentIndex(index)
            if incoming.entry.id == outgoing.entry.id {
                onRepeatLoop?()
            } else {
                emit(.currentIndexChanged(index))
                onItemTransition?(incoming.song, outgoing.song, true)
            }
        }
        onTimingChanged?()
        scheduleNext()
    }

    // MARK: Gapless hand-over

    /// Prerolls the incoming deck and starts it on the host clock at the outgoing item's last frame, then swaps the
    /// decks when that moment comes. When the incoming item is not ready in time the plan is dropped and the item's
    /// normal end loads the next one (a short gap rather than none).
    private func fireHandOver(_ plan: CrossfadePlan) async {
        guard let outgoing = activeItem, outgoing === plan.source else { return }
        func remainingSeconds() -> Double {
            (outgoing.durationSeconds - outgoing.positionSeconds) / Double(max(rate, 0.1))
        }
        func incomingReady() -> Bool {
            guard let prepared = preparedIncoming else { return false }
            return idle.isReadyToPreroll(prepared)
        }
        prepareIncoming(plan)
        while !incomingReady() {
            if Task.isCancelled { return }
            guard remainingSeconds() > 0.15, plannedTransition?.id == plan.id, activeItem === outgoing else {
                cancelCrossfadePlan()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let incoming = preparedIncoming else { return }
        let deck = idle
        _ = await deck.preroll(rate: rate)
        guard !Task.isCancelled, plannedTransition?.id == plan.id, activeItem === outgoing,
              preparedIncoming === incoming, playWhenReady else { return }
        let remaining = remainingSeconds()
        guard remaining > 0.02 else {
            cancelCrossfadePlan()
            return
        }
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        deck.start(rate: rate, atHostTime: CMTimeAdd(hostNow, CMTime(seconds: remaining,
                                                                      preferredTimescale: 1_000_000_000)))
        scheduledHandOver = ScheduledHandOver(planId: plan.id, incoming: incoming, outgoing: outgoing, deck: deck)
        try? await Task.sleep(for: .milliseconds(Int64(remaining * 1000)))
        guard !Task.isCancelled else { return }
        completeScheduledHandOver(planId: plan.id)
    }

    /// Swaps to the scheduled incoming deck: at its start time, or as soon as the outgoing item reports its end.
    /// Returns false when no hand-over (or not that one) is scheduled.
    @discardableResult
    func completeScheduledHandOver(planId: Int? = nil) -> Bool {
        guard let handOver = scheduledHandOver, planId == nil || handOver.planId == planId,
              handOver.deck === idle, activeItem === handOver.outgoing else { return false }
        let fadeRun = FadeRun(deck: active, item: handOver.outgoing, endMediaTime: handOver.outgoing.durationSeconds)
        swapDecks(to: handOver.incoming, from: handOver.outgoing, fade: fadeRun, startIncoming: false)
        return true
    }

    /// Cancels a hand-over scheduled on the host clock (pause, seek, re-plan); the incoming item stays prepared.
    func cancelScheduledHandOver() {
        guard let handOver = scheduledHandOver else { return }
        scheduledHandOver = nil
        handOver.deck.pause()
        handOver.deck.restoreStallWaiting()
        handOver.deck.seek(to: 0)
    }

    // MARK: Fades

    /// Ends the fade once the outgoing curve has reached 0 (checked against its media time, 10×/s, only while a fade
    /// runs and playback is not paused).
    func startFadeMonitor() {
        fadeMonitorTask?.cancel()
        fadeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, let fade = self.fade else { return }
                if fade.deck.currentItem == nil || fade.item.positionSeconds >= fade.endMediaTime + 0.05 {
                    self.finishFadeNow()
                    return
                }
            }
        }
    }

    /// Stops the outgoing deck and leaves the incoming item at full gain.
    func finishFadeNow() {
        fadeMonitorTask?.cancel()
        fadeMonitorTask = nil
        guard let running = fade else { return }
        fade = nil
        discard(running.deck.removeAll())
        activeItem?.tap.ramp.publish(nil)
    }

    /// Drops the planned crossfade / hand-over and the prepared incoming item (not a running fade).
    func cancelCrossfadePlan() {
        cancelScheduledHandOver()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        preparingIncomingTask?.cancel()
        preparingIncomingTask = nil
        plannedTransition = nil
        if let prepared = preparedIncoming {
            preparedIncoming = nil
            for deck in [deckA, deckB] where deck.items.contains(where: { $0 === prepared }) {
                deck.remove(prepared)
            }
            factory.discard(prepared)
        }
    }

    /// Pause: stop the countdown and the fade monitor (no timers while idle); the plan and prepared item stay.
    func suspendCrossfadeWork() {
        cancelScheduledHandOver()
        crossfadeTask?.cancel()
        crossfadeTask = nil
        fadeMonitorTask?.cancel()
        fadeMonitorTask = nil
    }

    /// Play: resume a paused fade and the countdown.
    func resumeCrossfadeWork() {
        if let running = fade {
            running.deck.play(rate: rate)
            startFadeMonitor()
        }
        if let plan = plannedTransition, crossfadeTask == nil, playWhenReady {
            runCountdown(plan, debounce: false)
        }
    }

    /// After a seek or a rate change: restart the countdown from the new position.
    func rescheduleCrossfadeCountdown() {
        guard let plan = plannedTransition, playWhenReady else { return }
        runCountdown(plan, debounce: false)
    }

    /// True while two decks overlap.
    var isTransitionRunning: Bool { fade != nil }
}
