import Foundation
import Observation
import os
import PixlLyrics
import QuartzCore

/// Per-row values the karaoke view draws with. Written by `LyricsDriver` only when the engine reports a change past
/// its epsilons, so a row view re-renders only when *its* values move (architecture §4, spec §5).
@Observable
final class LyricRowState {
    /// Top of the row in the lyrics viewport, scroll offset excluded.
    var y: CGFloat = CGFloat(LyricsEngine.offscreenY)
    var scale: CGFloat = 1
    /// Gaussian σ in points (0 = no blur).
    var blur: CGFloat = 0
    /// Depth falloff × background-vocal presence.
    var alpha: CGFloat = 1
    var activeness: Float = 0
    var hot = false
    /// Interlude / background-vocal expand factor.
    var expand: CGFloat = 1
    /// Far outside the viewport (or not placed yet): drawn at opacity 0.
    var culled = true
}

/// The lyrics time as hot rows read it, once per display-link tick. Only rows that are hot (normally one or two)
/// observe it, so a tick re-renders just those.
@Observable
final class LyricsHotClock {
    var nowMs: Int64 = 0
    /// The same time, unobserved, for rows fading out (their activeness tween already re-renders them).
    @ObservationIgnored var peekMs: Int64 = 0
}

/// Container-wide values (the user scroll).
@Observable
final class LyricsScrollState {
    var offset: CGFloat = 0
    var isUserScrolling = false
}

/// Owns the `CADisplayLink` that steps PixlLyrics' ported `LyricsEngine` (up to 120 Hz) with
/// `t = player position + sync offset`, and pushes only the changed per-row values into `LyricRowState`s. The link
/// pauses while playback is paused and the engine is at rest; a slow poll notices seeks made elsewhere meanwhile.
@MainActor
final class LyricsDriver: NSObject {
    let engine = LyricsEngine()
    let hotClock = LyricsHotClock()
    let scroll = LyricsScrollState()
    private(set) var rows: [LyricRowState] = []

    /// Frame-accurate player position (main thread, cheap).
    var positionProvider: () -> Int64 = { 0 }
    /// The additive lyric sync offset.
    var offsetMs: Int64 = 0 { didSet { if offsetMs != oldValue { wake() } } }
    /// UI tests: the song position the lyrics are frozen at (`-lyricsFreezeMs`).
    var frozenPositionMs: Int64?

    private var link: CADisplayLink?
    private var idlePoll: Timer?
    private var active = false
    private var viewportHeight: CGFloat = 0
    private let signposter = OSSignposter(subsystem: "io.github.redsn0w1877.pixlaudio", category: "Lyrics")

    // MARK: Lifecycle

    /// The lyrics are on screen: start ticking.
    func start() {
        guard !active else { return }
        active = true
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        wake()
    }

    /// Off screen: stop everything (the display link retains its target until invalidated).
    func stop() {
        active = false
        link?.invalidate()
        link = nil
        idlePoll?.invalidate()
        idlePoll = nil
    }

    func setPlaying(_ playing: Bool) {
        if engine.clock.isPlaying != playing {
            engine.clock.isPlaying = playing
            wake()
        }
    }

    func setConfig(_ config: LyricsEngineConfig) {
        if engine.config != config {
            engine.setConfig(config)
            wake()
        }
    }

    /// Installs a song's prepared lyrics. `animateIn` (song change, first show) runs the cascade from below.
    func setLyrics(_ prepared: PreparedLyrics?, animateIn: Bool) {
        if animateIn { engine.clock.reset() }
        engine.setLyrics(prepared, animateIn: animateIn)
        if engine.changes.contains(.rows) {
            rows = (0..<engine.rowCount).map { _ in LyricRowState() }
        }
        wake()
    }

    func setViewport(height: CGFloat, anchor: CGFloat) {
        viewportHeight = height
        engine.setViewport(height: Float(height), anchor: Float(anchor))
        wake()
    }

    func setRowHeight(_ row: Int, _ height: CGFloat) {
        guard row >= 0, row < engine.rowCount else { return }
        if engine.rowHeightValue(row) != Float(height) {
            engine.setRowHeight(row, Float(height))
            wake()
        }
    }

    // MARK: Gestures (forwarded to the engine)

    func lineTapped(_ lineIndex: Int) {
        engine.onLineTapped(lineIndex)
        engine.clock.markSeek()
        wake()
    }

    func dragStart() { engine.onDragStart(); wake() }
    func drag(_ dy: CGFloat) { engine.onDrag(Float(dy)); wake() }
    func dragEnd(velocity: CGFloat) { engine.onDragEnd(velocity: Float(velocity)); wake() }
    func scrollBy(_ dy: CGFloat) { engine.scrollBy(Float(dy)); wake() }

    // MARK: Frame loop

    /// Resumes the display link (any input that can move something calls this).
    func wake() {
        guard active, let link else { return }
        if link.isPaused {
            idlePoll?.invalidate()
            idlePoll = nil
            link.isPaused = false
        }
    }

    private func rawLyricsTime() -> Int64 {
        if let frozenPositionMs { return frozenPositionMs }
        return positionProvider() &+ offsetMs
    }

    @objc private func tick(_ link: CADisplayLink) {
        let nanos = Int64(link.targetTimestamp * 1_000_000_000)
        let raw = rawLyricsTime()
        let interval = signposter.beginInterval("LyricsEngine.step")
        engine.clock.tick(frameNanos: nanos, rawMs: raw)
        engine.step(frameNanos: nanos)
        signposter.endInterval("LyricsEngine.step", interval)
        push()
        if !engine.needsFrame { pause() }
    }

    private func pause() {
        guard let link, !link.isPaused else { return }
        link.isPaused = true
        engine.clock.rebase()
        // Paused and settled: poll slowly for a seek or an offset change made outside the lyrics.
        let poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.rawLyricsTime() != self.engine.clock.currentMs { self.wake() }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        idlePoll = poll
    }

    /// Writes the engine's changed outputs into the observable row states.
    private func push() {
        let t = engine.clock.currentMs
        hotClock.peekMs = t
        let engineChanges = engine.changes
        if engineChanges.contains(.scrollOffset) { scroll.offset = CGFloat(engine.scrollOffset) }
        if engineChanges.contains(.userScrolling) { scroll.isUserScrolling = engine.isUserScrolling }

        var anyHot = false
        for r in engine.changedRows where r < rows.count {
            let change = engine.rowChanges[r]
            let state = rows[r]
            if change.contains(.y) { state.y = CGFloat(engine.rowY[r]) }
            if change.contains(.scale) { state.scale = CGFloat(engine.rowScale[r]) }
            if change.contains(.blur) { state.blur = CGFloat(engine.rowBlurSigma[r]) }
            if change.contains(.depthAlpha) || change.contains(.presence) {
                state.alpha = CGFloat(min(max(engine.rowDepthAlpha[r] * engine.rowPresence[r], 0), 1))
            }
            if change.contains(.activeness) { state.activeness = engine.rowActiveness[r] }
            if change.contains(.hot) { state.hot = engine.rowHot[r] }
            if change.contains(.expand) { state.expand = CGFloat(engine.rowExpand[r]) }
        }
        // Culling: rows further than half a viewport outside are not drawn (cheap loop, writes only flips).
        let height = viewportHeight
        let margin = height * CGFloat(LyricsRenderMetrics.cullMarginFraction)
        let offset = CGFloat(engine.scrollOffset)
        for r in 0..<rows.count {
            let state = rows[r]
            if engine.rowHot[r] { anyHot = true }
            let placed = engine.isPlaced(r)
            let top = CGFloat(engine.rowY[r]) + offset
            let h = CGFloat(max(engine.rowHeightValue(r), 0))
            let culled = !placed || height <= 0 || top > height + margin || top + h < -margin
            if state.culled != culled { state.culled = culled }
        }
        if anyHot && hotClock.nowMs != t { hotClock.nowMs = t }
        engine.clearChanges()
    }
}
