import Foundation
import PixlAudioCore
import PixlModel

/// A crossfade planned for the current item (`TransitionController.scheduleTransitionFor`).
struct CrossfadePlan {
    let id: Int
    /// The item the plan was made for (a different current item invalidates it).
    let source: DeckItem
    let targetEntry: QueueEntry
    let settings: TransitionSettings
    let transitionPointMs: Int64
    let fadeMs: Int64
}

/// A running fade: the outgoing deck keeps playing until its gain curve reaches 0.
struct FadeRun {
    let deck: Deck
    let item: DeckItem
    /// Media time of the outgoing item at which its curve ends.
    let endMediaTime: Double
}

/// Android's overlap crossfade (`DualPlayerEngine.performOverlapTransition` + `TransitionController`), with the pure
/// decisions from PixlAudioCore's `TransitionRuleResolver` / `CrossfadeScheduler` and the gains applied inside each
/// item's processing tap (`CrossfadeRamp`, evaluated from the item's own media time). Every mode except NONE runs the
/// same overlap; FADE_IN_OUT, OVERLAP and SMOOTH differ through their curves (Android behaviour).
extension DualDeckEngine {
    /// The plan for `current`, or nil when it should hand over gaplessly (mode NONE, crossfade off globally, no next
    /// song, track too short, transitions suspended).
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

    func startCrossfade(_ plan: CrossfadePlan) {
        plannedCrossfade = plan
        guard playWhenReady else { return }   // the countdown starts on play
        runCountdown(plan, debounce: true)
    }

    /// Sleeps towards the transition point (speed-scaled, waking more often near it), prepares the incoming item on
    /// the idle deck after the debounce, then fires.
    private func runCountdown(_ plan: CrossfadePlan, debounce: Bool) {
        crossfadeTask?.cancel()
        let remainingAtStart = plan.transitionPointMs - currentPositionMs()
        let debounceMs = debounce ? min(CrossfadeScheduler.debounceMs, max(remainingAtStart / 2, 0)) : 0
        crossfadeTask = Task { [weak self] in
            if debounceMs > 0 { try? await Task.sleep(for: .milliseconds(debounceMs)) }
            guard let self, !Task.isCancelled, self.plannedCrossfade?.id == plan.id else { return }
            self.prepareIncoming(plan)
            while !Task.isCancelled {
                let remaining = plan.transitionPointMs - self.currentPositionMs()
                if remaining <= 0 { break }
                let sleepMs = CrossfadeScheduler.countdownSleepMs(remainingMs: remaining, speed: self.rate)
                try? await Task.sleep(for: .milliseconds(sleepMs))
            }
            guard !Task.isCancelled, self.plannedCrossfade?.id == plan.id else { return }
            await self.fire(plan)
        }
    }

    /// Builds the incoming item and parks it, paused and silent (its curve starts at 0), on the idle deck.
    private func prepareIncoming(_ plan: CrossfadePlan) {
        guard preparedIncoming == nil, preparingIncomingTask == nil else { return }
        // A fade still finishing on the idle deck ends now (only possible with very short tracks).
        finishFadeNow()
        preparingIncomingTask = Task { [weak self] in
            guard let self else { return }
            let item = try? await self.factory.makeItem(for: plan.targetEntry)
            self.preparingIncomingTask = nil
            guard let item else { return }
            guard !Task.isCancelled, self.plannedCrossfade?.id == plan.id, self.fade == nil else {
                self.factory.discard(item)
                return
            }
            item.tap.ramp.publish(CrossfadeRamp(role: .incoming, curve: plan.settings.curveIn, startTime: 0,
                                                duration: Double(max(plan.fadeMs, CrossfadeRun.minimumDurationMs)) / 1000,
                                                scale: 1))
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
        guard let incoming = preparedIncoming, activeItem === outgoing, plannedCrossfade?.id == plan.id else {
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

        let outgoingDeck = active
        let incomingDeck = idle
        active = incomingDeck
        preparedIncoming = nil
        plannedCrossfade = nil
        crossfadeTask = nil
        activeItem = incoming
        fade = FadeRun(deck: outgoingDeck, item: outgoing, endMediaTime: outgoingStart + Double(run.durationMs) / 1000)
        if playWhenReady {
            startActive()
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

    /// Drops the planned crossfade and the prepared incoming item (not a running fade).
    func cancelCrossfadePlan() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        preparingIncomingTask?.cancel()
        preparingIncomingTask = nil
        plannedCrossfade = nil
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
        if let plan = plannedCrossfade, crossfadeTask == nil, playWhenReady {
            runCountdown(plan, debounce: false)
        }
    }

    /// After a seek or a rate change: restart the countdown from the new position.
    func rescheduleCrossfadeCountdown() {
        guard let plan = plannedCrossfade, playWhenReady else { return }
        runCountdown(plan, debounce: false)
    }

    /// True while two decks overlap.
    var isTransitionRunning: Bool { fade != nil }
}
