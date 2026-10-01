// Port of `presentation/lyrics/LyricsEngine.kt` (spec §3–4): one plain object advanced by `step` from a single frame
// loop (a `CADisplayLink` on iOS), never one animation object per line.
//
// Android writes Compose snapshot state per row; here every output is a flat array the driver reads after `step`,
// with a per-row change mask (`rowChanges`) and a list of changed rows (`changedRows`) so it only pushes what moved
// into its per-row observable state. Values are written only when they move past the same epsilons as Android
// (y 0.25, scale 0.0005, blur quantised, activeness/expand 0.002) or settle. Change flags accumulate until the
// driver calls `clearChanges()` (gesture calls between frames set them too).
//
// ```
// // CADisplayLink tick, main thread:
// engine.step(frameNanos: link.timestampNanos, positionMs: player.lyricsPositionMs, offsetMs: syncOffset)
// for r in engine.changedRows { lineStates[r].apply(engine, row: r) }
// engine.clearChanges()
// link.isPaused = !engine.needsFrame
// ```
//
// Every per-frame computation runs on preallocated arrays; the hot set comes from a binary search over the
// pre-sorted start times.

import Foundation
import PixlFoundation

/// Engine configuration.
public struct LyricsEngineConfig: Sendable, Hashable {
    /// Device pixels per layout unit. On iOS layout is in points, so 1 (the snap margin is then 300 pt).
    public var density: Float
    /// A real blur is available. When false, depth is shown through `rowDepthAlpha` instead (Android API 30).
    public var blurSupported: Bool
    /// The "animated lyrics blur" preference (and not increased contrast).
    public var blurEnabled: Bool
    /// Multiplier on the spec's σ table; 1 gives 1.6 / 2.4 / 3.2 / 4.0 / 4.8.
    public var blurStrength: Float
    /// Springs snap and the stagger is 0; activeness still fades.
    public var reducedMotion: Bool
    /// iOS only: quantum of the published σ (`rowBlurSigma`, points). Android quantises its Skia radius to 1.5 px,
    /// ≈ 0.3 pt of σ at 3× density.
    public var blurSigmaQuantum: Float

    public init(density: Float = 1, blurSupported: Bool = true, blurEnabled: Bool = true, blurStrength: Float = 1,
                reducedMotion: Bool = false, blurSigmaQuantum: Float = 0.3) {
        self.density = density
        self.blurSupported = blurSupported
        self.blurEnabled = blurEnabled
        self.blurStrength = blurStrength
        self.reducedMotion = reducedMotion
        self.blurSigmaQuantum = blurSigmaQuantum
    }
}

/// Which per-row outputs changed since the last `LyricsEngine.clearChanges()`.
public struct LyricRowChange: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let y = LyricRowChange(rawValue: 1 << 0)
    public static let scale = LyricRowChange(rawValue: 1 << 1)
    /// `rowBlurSigma` and/or `rowBlurRadiusPx`.
    public static let blur = LyricRowChange(rawValue: 1 << 2)
    public static let depthAlpha = LyricRowChange(rawValue: 1 << 3)
    public static let activeness = LyricRowChange(rawValue: 1 << 4)
    public static let hot = LyricRowChange(rawValue: 1 << 5)
    public static let expand = LyricRowChange(rawValue: 1 << 6)
    public static let presence = LyricRowChange(rawValue: 1 << 7)
    public static let prefetch = LyricRowChange(rawValue: 1 << 8)
}

/// Engine-wide outputs that changed since the last `LyricsEngine.clearChanges()`.
public struct LyricsEngineChange: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `setLyrics` replaced every row: rebuild per-row state from the outputs.
    public static let rows = LyricsEngineChange(rawValue: 1 << 0)
    public static let scrollOffset = LyricsEngineChange(rawValue: 1 << 1)
    public static let userScrolling = LyricsEngineChange(rawValue: 1 << 2)
}

// MARK: - Animation channels: preallocated arrays, no per-frame allocation.

struct SpringChannel {
    static let maxSpringNanos: Int64 = 10_000_000_000

    var value: [Float]
    var velocity: [Float]
    var target: [Float]
    var active: [Bool]
    private var from: [Float]
    private var v0: [Float]
    private var startNanos: [Int64]
    private var specs: [FloatSpringSpec?]
    private let restDelta: Float
    private let restVelocity: Float

    init(size: Int, restDelta: Float, restVelocity: Float) {
        value = [Float](repeating: 0, count: size)
        velocity = value
        target = value
        from = value
        v0 = value
        active = [Bool](repeating: false, count: size)
        startNanos = [Int64](repeating: 0, count: size)
        specs = [FloatSpringSpec?](repeating: nil, count: size)
        self.restDelta = restDelta
        self.restVelocity = restVelocity
    }

    mutating func snap(_ i: Int, _ v: Float) {
        value[i] = v
        velocity[i] = 0
        target[i] = v
        from[i] = v
        v0[i] = 0
        active[i] = false
    }

    /// Restarts toward `newTarget` from the current value and velocity (call `update` first this frame).
    mutating func animateTo(_ i: Int, _ newTarget: Float, _ spec: FloatSpringSpec, _ nowNanos: Int64) {
        if !active[i] && value[i] == newTarget {
            target[i] = newTarget
            return
        }
        from[i] = value[i]
        v0[i] = velocity[i]
        target[i] = newTarget
        specs[i] = spec
        startNanos[i] = nowNanos
        active[i] = true
    }

    /// Moves the whole motion by `delta` without changing its shape.
    mutating func shift(_ i: Int, _ delta: Float) {
        value[i] += delta
        from[i] += delta
        target[i] += delta
    }

    /// Evaluates the closed-form spring at `nowNanos`; returns whether it is still moving.
    @discardableResult
    mutating func update(_ i: Int, _ nowNanos: Int64) -> Bool {
        if !active[i] { return false }
        guard let spec = specs[i] else {
            snap(i, target[i])
            return false
        }
        let dt = Swift.max(nowNanos &- startNanos[i], 0)
        let m = spec.motionFromNanos(dt, initialValue: from[i], targetValue: target[i], initialVelocity: v0[i])
        if (abs(m.value - target[i]) < restDelta && abs(m.velocity) < restVelocity) || dt > Self.maxSpringNanos {
            snap(i, target[i])
            return false
        }
        value[i] = m.value
        velocity[i] = m.velocity
        return true
    }
}

struct TweenChannel {
    var value: [Float]
    var to: [Float]
    var active: [Bool]
    private var from: [Float]
    private var startNanos: [Int64]
    private var durationNanos: [Int64]
    /// nil = linear.
    private var easings: [CubicBezierEasing?]

    init(size: Int) {
        value = [Float](repeating: 0, count: size)
        to = value
        from = value
        active = [Bool](repeating: false, count: size)
        startNanos = [Int64](repeating: 0, count: size)
        durationNanos = startNanos
        easings = [CubicBezierEasing?](repeating: nil, count: size)
    }

    mutating func snap(_ i: Int, _ v: Float) {
        value[i] = v
        from[i] = v
        to[i] = v
        active[i] = false
    }

    /// Starts a tween from the current value unless it is already heading to `target`.
    mutating func animateTo(_ i: Int, _ target: Float, _ durationMs: Int64, _ easing: CubicBezierEasing?, _ nowNanos: Int64) {
        if to[i] == target { return }
        if durationMs <= 0 {
            snap(i, target)
            return
        }
        from[i] = value[i]
        to[i] = target
        startNanos[i] = nowNanos
        durationNanos[i] = durationMs &* 1_000_000
        easings[i] = easing
        active[i] = true
    }

    @discardableResult
    mutating func update(_ i: Int, _ nowNanos: Int64) -> Bool {
        if !active[i] { return false }
        let f = (Float(nowNanos &- startNanos[i]) / Float(durationNanos[i])).coerced(in: 0, 1)
        if f >= 1 {
            snap(i, to[i])
            return false
        }
        let e = easings[i]?.transform(f) ?? f
        value[i] = from[i] + (to[i] - from[i]) * e
        return true
    }
}

// MARK: - The engine

/// The lyrics motion engine.
///
/// Inputs: `setLyrics`, `setViewport`, `setRowHeight` (from measurement), `setConfig`, `clock.isPlaying`, and the
/// gesture calls (`onDragStart`, `onDrag`, `onDragEnd`, `onLineTapped`, `scrollBy`). Outputs: the `row…` arrays,
/// `scrollOffset`, `isUserScrolling`, `isAtRest` / `needsFrame` and the change masks.
public final class LyricsEngine {

    /// Where rows sit before the first layout (renderers skip them: see `isPlaced`).
    public static let offscreenY: Float = 1_000_000

    public static let leadInMs: Int64 = 250
    /// How far ahead of turning hot a line is asked to build its word pieces.
    public static let prefetchLeadMs: Int64 = 1_000
    public static let inactiveScale: Float = 0.97
    public static let backgroundCollapsedScale: Float = 0.75
    public static let backgroundExpandFromScale: Float = 0.8
    public static let backgroundSlideFraction: Float = 0.8
    public static let activateMs: Int64 = 300
    public static let deactivateMs: Int64 = 450
    public static let blurTweenMs: Int64 = 400
    public static let blurDragMs: Int64 = 250
    public static let snapMarginDp: Float = 300
    public static let firstShowStartFactor: Float = 2
    public static let minFlingVelocityPxPerSec: Float = 100
    public static let flingFrictionMultiplier: Float = 0.733
    public static let flingAbsVelocityThreshold: Float = 50
    public static let snapBackIdleMs: Int64 = 4_500
    public static let snapBackMinIdleMs: Int64 = 500
    public static let tapSlowWindowMs: Int64 = 1_500
    public static let bottomLimitFraction: Float = 0.5

    static let yEps: Float = 0.25
    static let scaleEps: Float = 0.0005
    static let activenessEps: Float = 0.002
    static let expandEps: Float = 0.002
    static let ms: Int64 = 1_000_000

    /// Index of the first element of `sorted` greater than `key` (the upper bound).
    public static func upperBound(_ sorted: [Int64], _ key: Int64) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = Int(UInt(bitPattern: lo + hi) >> 1)
            if sorted[mid] <= key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Clock and configuration

    /// The lyrics time base. Tick it once per frame before `step(frameNanos:)`, or use
    /// `step(frameNanos:positionMs:offsetMs:)`, which does both. Set `clock.isPlaying` from the player.
    public var clock: LyricsClock

    public private(set) var config = LyricsEngineConfig()

    public init(clock: LyricsClock = LyricsClock()) {
        self.clock = clock
    }

    public func setConfig(_ config: LyricsEngineConfig) {
        self.config = config
    }

    // MARK: Model

    public private(set) var prepared: PreparedLyrics?
    public private(set) var rowCount = 0
    private var lineCount = 0
    private var rowLine: [Int] = []            // line index, -1 for interlude rows
    private var lineRow: [Int] = []
    private var lineGroupLead: [Int] = []
    private var lineIsLeader: [Bool] = []
    private var rowIsBg: [Bool] = []           // grouped background vocal
    private var rowBgAbove: [Bool] = []
    private var rowLeaderOrdinal: [Int] = []   // ordinal among leader rows, -1 otherwise
    private var rowNextLeaderOrdinal: [Int] = []
    private var rowG0: [Int64] = []
    private var rowG1: [Int64] = []
    private var interludeRows: [Int] = []
    private var leaderRows: [Int] = []
    private var starts: [Int64] = []
    private var ends: [Int64] = []
    private var maxLineDurationMs: Int64 = 0
    private var lastEndMs: Int64 = 0

    // MARK: Hot set

    private var lineHot: [Bool] = []
    private var groupHot: [Bool] = []          // by leader line index
    private var hotList: [Int] = []
    private var hotCount = 0

    // MARK: Layout

    private var rowHeight: [Float] = []        // measured full height, -1 = unknown
    private var effHeight: [Float] = []
    private var prefix: [Float] = []           // size rowCount + 1
    private var targetY: [Float] = []
    private var tops: [Float] = []             // scratch for the cascade
    private var delays: [Float] = []
    public private(set) var viewportHeight: Float = 0
    public private(set) var anchorY: Float = 0
    private var minOffset: Float = 0
    private var maxOffset: Float = 0

    // MARK: Motion

    private var y = SpringChannel(size: 0, restDelta: 0.1, restVelocity: 5)
    private var scale = SpringChannel(size: 0, restDelta: 0.0002, restVelocity: 0.002)
    private var bgExpand = SpringChannel(size: 0, restDelta: 0.001, restVelocity: 0.01)
    private var activeness = TweenChannel(size: 0)
    private var presence = TweenChannel(size: 0)
    private var sigma = TweenChannel(size: 0)
    private var depthAlpha = TweenChannel(size: 0)
    private var rowSpec: [FloatSpringSpec?] = []
    private var pendingAt: [Int64] = []
    private var pendingSpec: [FloatSpringSpec?] = []

    // MARK: Published outputs (Android's `pub…` shadows, which are what the snapshot state holds)

    /// Top of the row from the top of the lyrics viewport, **excluding** `scrollOffset` (add it when placing).
    /// Includes the background-vocal slide. `offscreenY` until the first layout.
    public private(set) var rowY: [Float] = []
    /// Layer scale. Pivot `(0, 0.5)`, or `(1, 0.5)` for duet / RTL lines (`LyricsLayoutMath.pivotX`).
    public private(set) var rowScale: [Float] = []
    /// iOS output: Gaussian σ in points (already × blur strength), quantised to `config.blurSigmaQuantum`. 0 = none.
    public private(set) var rowBlurSigma: [Float] = []
    /// Android output: the Skia blur radius in px, quantised to 1.5 px (kept for parity with the Android goldens).
    public private(set) var rowBlurRadiusPx: [Float] = []
    /// No-blur depth falloff: multiply the inactive alpha by this. 1 when blur is supported.
    public private(set) var rowDepthAlpha: [Float] = []
    /// Line activeness `a` in 0…1 (300 ms up, 450 ms down). 0 for interlude rows.
    public private(set) var rowActiveness: [Float] = []
    /// Line hot (`start − 250 ≤ t < end`), or interlude in progress. Only hot rows read the clock per frame.
    public private(set) var rowHot: [Bool] = []
    /// Height factor: interlude expand, background-vocal expand; 1 for other lines.
    public private(set) var rowExpand: [Float] = []
    /// Alpha multiplier for grouped background vocals (0 while collapsed); 1 for other rows.
    public private(set) var rowPresence: [Float] = []
    /// The line turns hot within about `prefetchLeadMs` (and has not ended): build its word pieces now. Latches.
    public private(set) var rowPrefetch: [Bool] = []

    /// Per-row change mask since the last `clearChanges()`.
    public private(set) var rowChanges: [LyricRowChange] = []
    /// Rows whose `rowChanges` is non-empty, in the order they first changed.
    public private(set) var changedRows: [Int] = []
    /// Engine-wide changes since the last `clearChanges()`.
    public private(set) var changes: LyricsEngineChange = []

    /// Clears `rowChanges`, `changedRows` and `changes` (call after pushing the changed values).
    public func clearChanges() {
        for r in changedRows { rowChanges[r] = [] }
        changedRows.removeAll(keepingCapacity: true)
        changes = []
    }

    /// False until the engine has positioned the row for the first time.
    public func isPlaced(_ row: Int) -> Bool { rowY[row] < Self.offscreenY / 2 }

    // MARK: Lifecycle flags

    private var laidOut = false
    private var animateInPending = false
    private var snapChannelsPending = false
    private var resizePending = false
    private var lastScrollTarget = -1
    private var slowUntilNanos: Int64 = -1
    private var tapPending = false
    private var resetScrollStatePending = false

    /// Current scroll-target row (-1 before the first step).
    public var scrollTargetRow: Int { lastScrollTarget }

    /// The row layout is anchored on (the frozen row during a user scroll, else the scroll target), or -1 before the
    /// first step.
    public var layoutAnchorRow: Int { userScroll ? frozenAnchorRow : lastScrollTarget }

    /// The live scroll offset (same value as `scrollOffset`).
    public var rawScrollOffset: Float { offset }

    /// The scroll target at lyrics time `t` before the first `step` has run (what the first layout will anchor on),
    /// or -1 with no rows. Touches only the hot-set scratch that every step recomputes.
    public func predictScrollTargetRow(_ t: Int64) -> Int {
        if prepared == nil || rowCount == 0 { return -1 }
        updateHotSet(t)
        return resolveScrollTargetRow(t)
    }

    // MARK: User scroll

    private var offset: Float = 0
    private var userScroll = false
    private var frozenAnchorRow = 0
    private var dragging = false
    private var flinging = false
    private var flingFrom: Float = 0
    private var flingVelocity: Float = 0
    private var flingStartNanos: Int64 = -1
    private var flingDurationNanos: Int64 = 0
    private var scrollEndPending = false
    private var scrollEndedNanos: Int64 = -1
    private let decay = FloatExponentialDecaySpec(frictionMultiplier: LyricsEngine.flingFrictionMultiplier,
                                                  absVelocityThreshold: LyricsEngine.flingAbsVelocityThreshold)

    /// User scroll offset, added to every row's `rowY` when placing.
    public private(set) var scrollOffset: Float = 0

    /// True between the start of a drag and the snap-back to auto-follow.
    public private(set) var isUserScrolling = false

    /// Whether everything is settled: no spring, tween, pending cascade, fling or scroll timer.
    public private(set) var isAtRest = true

    /// The frame loop may pause when this is false (paused and settled).
    public var needsFrame: Bool {
        clock.isPlaying || !isAtRest || tapPending || resizePending || (prepared != nil && !laidOut && layoutInputsReady())
    }

    // MARK: - Inputs

    /// Installs a new model. `animateIn` (song change, first show): every line starts at `2 × viewportHeight` and
    /// cascades up. Otherwise (a rebuild of the same song) rows snap into place with no stagger.
    ///
    /// An equal model is ignored (Android skips the identical instance, and its view only calls this when the model
    /// changes by equality — `remember(engine, prepared)`); pass a different model to re-install.
    public func setLyrics(_ prepared: PreparedLyrics?, animateIn: Bool) {
        if prepared == self.prepared { return }
        self.prepared = prepared
        let lines = prepared?.lines ?? []
        let modelRows = prepared?.rows ?? []
        lineCount = lines.count
        rowCount = modelRows.count
        let n = rowCount

        rowLine = [Int](repeating: -1, count: n)
        lineRow = [Int](repeating: 0, count: lineCount)
        lineGroupLead = [Int](repeating: 0, count: lineCount)
        lineIsLeader = [Bool](repeating: false, count: lineCount)
        rowIsBg = [Bool](repeating: false, count: n)
        rowBgAbove = [Bool](repeating: false, count: n)
        rowLeaderOrdinal = [Int](repeating: -1, count: n)
        rowNextLeaderOrdinal = [Int](repeating: -1, count: n)
        rowG0 = [Int64](repeating: 0, count: n)
        rowG1 = [Int64](repeating: 0, count: n)
        starts = [Int64](repeating: 0, count: lineCount)
        ends = [Int64](repeating: 0, count: lineCount)

        for (i, line) in lines.enumerated() {
            starts[i] = line.startMs
            ends[i] = line.endMs
            lineGroupLead[i] = line.groupLeadIndex.coerced(in: 0, lineCount - 1)
            lineIsLeader[i] = line.isGroupLead
        }
        var interludes: [Int] = []
        var leaders: [Int] = []
        for (r, row) in modelRows.enumerated() {
            switch row {
            case .line(let l):
                rowLine[r] = l
                lineRow[l] = r
                let line = lines[l]
                rowIsBg[r] = line.isGroupedBackground
                rowBgAbove[r] = line.bgAbove
                if line.isGroupLead {
                    rowLeaderOrdinal[r] = leaders.count
                    leaders.append(r)
                }
            case .interlude(let startMs, let endMs, _):
                rowG0[r] = startMs
                rowG1[r] = endMs
                rowNextLeaderOrdinal[r] = leaders.count // the next leader gets this ordinal
                interludes.append(r)
            }
        }
        interludeRows = interludes
        leaderRows = leaders
        maxLineDurationMs = prepared?.maxLineDurationMs ?? 0
        lastEndMs = prepared?.lastEndMs ?? 0

        lineHot = [Bool](repeating: false, count: lineCount)
        groupHot = [Bool](repeating: false, count: lineCount)
        hotList = [Int](repeating: 0, count: lineCount)
        hotCount = 0

        rowHeight = [Float](repeating: -1, count: n)
        effHeight = [Float](repeating: 0, count: n)
        prefix = [Float](repeating: 0, count: n + 1)
        targetY = [Float](repeating: 0, count: n)
        tops = [Float](repeating: 0, count: n)
        delays = [Float](repeating: 0, count: n)

        y = SpringChannel(size: n, restDelta: 0.1, restVelocity: 5)
        scale = SpringChannel(size: n, restDelta: 0.0002, restVelocity: 0.002)
        bgExpand = SpringChannel(size: n, restDelta: 0.001, restVelocity: 0.01)
        activeness = TweenChannel(size: n)
        presence = TweenChannel(size: n)
        sigma = TweenChannel(size: n)
        depthAlpha = TweenChannel(size: n)
        rowSpec = [FloatSpringSpec?](repeating: nil, count: n)
        pendingAt = [Int64](repeating: -1, count: n)
        pendingSpec = [FloatSpringSpec?](repeating: nil, count: n)
        for r in 0..<n {
            y.snap(r, Self.offscreenY)
            scale.snap(r, 1)
            bgExpand.snap(r, 0)
            presence.snap(r, rowIsBg[r] ? 0 : 1)
            depthAlpha.snap(r, 1)
        }

        rowY = [Float](repeating: Self.offscreenY, count: n)
        rowScale = [Float](repeating: 1, count: n)
        rowBlurSigma = [Float](repeating: 0, count: n)
        rowBlurRadiusPx = [Float](repeating: 0, count: n)
        rowDepthAlpha = [Float](repeating: 1, count: n)
        rowActiveness = [Float](repeating: 0, count: n)
        rowExpand = [Float](repeating: 1, count: n)
        rowPresence = [Float](repeating: 1, count: n)
        rowHot = [Bool](repeating: false, count: n)
        rowPrefetch = [Bool](repeating: false, count: n)
        rowChanges = [LyricRowChange](repeating: [], count: n)
        changedRows = []
        changedRows.reserveCapacity(n)
        changes.insert(.rows)

        laidOut = false
        animateInPending = animateIn
        snapChannelsPending = !animateIn
        resizePending = false
        lastScrollTarget = -1
        slowUntilNanos = -1
        tapPending = false
        // Scroll state resets on the next step.
        userScroll = false
        dragging = false
        flinging = false
        scrollEndPending = false
        scrollEndedNanos = -1
        offset = 0
        resetScrollStatePending = true
        isAtRest = false
    }

    /// Measured full height of `row` (for interlude and background rows: the expanded height). The view may pass an
    /// estimate for a row it has not measured yet; it only does so for rows that are off-screen.
    public func setRowHeight(_ row: Int, _ height: Float) {
        guard row >= 0 && row < rowCount else { return }
        rowHeight[row] = height.coerced(atLeast: 0)
    }

    /// The height last passed to `setRowHeight`, or -1 when unknown.
    public func rowHeightValue(_ row: Int) -> Float { rowHeight[row] }

    /// Viewport height and the anchor (top of the active line, normally `0.25 × height`, at least header height +
    /// 16 pt).
    public func setViewport(height: Float, anchor: Float) {
        if height == viewportHeight && anchor == anchorY { return }
        viewportHeight = height
        anchorY = anchor
        if laidOut { resizePending = true }
    }

    /// Tap on a line: leave user scroll now, and move with the slow spring and no stagger.
    public func onLineTapped(_ lineIndex: Int) {
        tapPending = true
    }

    public func onDragStart() {
        dragging = true
        flinging = false
        scrollEndPending = false
        scrollEndedNanos = -1
        if !userScroll {
            userScroll = true
            setUserScrolling(true)
            frozenAnchorRow = Swift.max(lastScrollTarget, 0)
            // A user scroll starts with the stagger off: fire every delayed retarget now.
            for r in 0..<rowCount where pendingAt[r] >= 0 { pendingAt[r] = 0 }
        }
    }

    /// Drag by `dy` (positive = content moves down), applied directly with no spring.
    public func onDrag(_ dy: Float) {
        if !userScroll || !dragging { onDragStart() }
        setOffset((offset + dy).coerced(in: minOffset, maxOffset))
    }

    /// End of a drag. Below 100 px/s there is no coasting.
    public func onDragEnd(velocity: Float) {
        if !dragging { return }
        dragging = false
        if abs(velocity) >= Self.minFlingVelocityPxPerSec {
            flinging = true
            flingFrom = offset
            flingVelocity = velocity
            flingStartNanos = -1
        } else {
            scrollEndPending = true
        }
    }

    /// Accessibility / programmatic scroll: a drag of `dy` with no fling.
    public func scrollBy(_ dy: Float) {
        onDragStart()
        onDrag(dy)
        onDragEnd(velocity: 0)
    }

    /// The row under `y` (view coordinates, scroll offset included), or -1. Collapsible rows use their current
    /// expand factor; rows with unknown height, or that `isMeasured` rejects, are never hit.
    public func hitRow(y: Float, isMeasured: (Int) -> Bool = { _ in true }) -> Int {
        for r in 0..<rowCount where rowHeight[r] >= 0 && isMeasured(r) {
            let top = rowY[r] + scrollOffset
            let collapsible = rowLine[r] < 0 || rowIsBg[r]
            let h = rowHeight[r] * (collapsible ? rowExpand[r].coerced(in: 0, 1) : 1)
            if h > 0 && y >= top && y < top + h { return r }
        }
        return -1
    }

    // MARK: - Frame

    /// Ticks `clock` with the player position and steps the engine: the display-link entry point.
    public func step(frameNanos: Int64, positionMs: Int64, offsetMs: Int64 = 0) {
        clock.tick(frameNanos: frameNanos, positionMs: positionMs, offsetMs: offsetMs)
        step(frameNanos: frameNanos)
    }

    /// Advances every channel to `frameNanos` using the clock's current state (tick the clock first).
    public func step(frameNanos: Int64) {
        let now = frameNanos
        guard prepared != nil, rowCount > 0 else {
            if offset != 0 { setOffset(0) }
            if isUserScrolling { setUserScrolling(false) }
            isAtRest = true
            return
        }
        if resetScrollStatePending {
            resetScrollStatePending = false
            setOffset(0)
            if isUserScrolling { setUserScrolling(false) }
        }

        let t = clock.currentMs
        let seek = clock.consumeSeek()
        let playing = clock.isPlaying
        let reduced = config.reducedMotion

        // 1. Evaluate every channel at `now` so retargets start from current values.
        for r in 0..<rowCount {
            y.update(r, now)
            scale.update(r, now)
            bgExpand.update(r, now)
            activeness.update(r, now)
            presence.update(r, now)
            sigma.update(r, now)
            depthAlpha.update(r, now)
        }

        // 2. Hot set, then the non-positional targets.
        updateHotSet(t)
        let snapChannels = snapChannelsPending
        snapChannelsPending = false
        for r in 0..<rowCount {
            let line = rowLine[r]
            if line < 0 { continue }
            let hot = lineHot[line]
            let a: Float = hot ? 1 : 0
            if snapChannels {
                activeness.snap(r, a)
            } else {
                activeness.animateTo(r, a, hot ? Self.activateMs : Self.deactivateMs, EmphasisMath.easeOut, now)
            }

            if rowIsBg[r] {
                let gh = groupHot[lineGroupLead[line]]
                let target: Float = gh ? 1 : 0
                if snapChannels {
                    presence.snap(r, target)
                } else {
                    presence.animateTo(r, target, gh ? Self.activateMs : Self.deactivateMs, EmphasisMath.easeOut, now)
                }
                if bgExpand.target[r] != target || (snapChannels && bgExpand.value[r] != target) {
                    if reduced || snapChannels { bgExpand.snap(r, target) } else { bgExpand.animateTo(r, target, LyricsSprings.background, now) }
                }
            } else {
                let target: Float = (!playing || hot) ? 1 : Self.inactiveScale
                if scale.target[r] != target || (snapChannels && scale.value[r] != target) {
                    if reduced || snapChannels { scale.snap(r, target) } else { scale.animateTo(r, target, LyricsSprings.scale, now) }
                }
            }
        }

        // 3. Effective heights and prefix sums.
        var inputsReady = viewportHeight > 0
        prefix[0] = 0
        for r in 0..<rowCount {
            let h = rowHeight[r]
            if h < 0 { inputsReady = false }
            let full = h.coerced(atLeast: 0)
            if rowLine[r] < 0 {
                effHeight[r] = full * InterludeTimeline.expand(tMs: t, g0: rowG0[r], g1: rowG1[r])
            } else if rowIsBg[r] {
                effHeight[r] = full * bgExpand.value[r].coerced(in: 0, 1)
            } else {
                effHeight[r] = full
            }
            prefix[r + 1] = prefix[r] + effHeight[r]
        }

        // 4. Scroll target and user-scroll bookkeeping.
        let target = resolveScrollTargetRow(t)
        let targetChanged = laidOut && target != lastScrollTarget
        var event: FloatSpringSpec?
        var eventStagger = false

        if tapPending {
            tapPending = false
            slowUntilNanos = now &+ Self.tapSlowWindowMs &* Self.ms
            if userScroll && !dragging {
                snapBack()
                event = LyricsSprings.slow
            }
        }
        let forcedSlow = slowUntilNanos >= 0 && now <= slowUntilNanos

        if userScroll {
            if scrollEndPending {
                scrollEndPending = false
                scrollEndedNanos = now
            }
            stepFling(now)
            let idle: Int64 = (scrollEndedNanos >= 0 && !dragging && !flinging) ? now &- scrollEndedNanos : -1
            let snap: Bool
            if seek && !dragging {
                snap = true
            } else if idle < 0 {
                snap = false
            } else if idle >= Self.snapBackIdleMs &* Self.ms {
                snap = true
            } else if targetChanged && idle >= Self.snapBackMinIdleMs &* Self.ms && isRowInViewport(target) {
                snap = true
            } else {
                snap = false
            }
            if snap {
                snapBack()
                event = LyricsSprings.slow
            }
        } else if targetChanged {
            let noStagger = seek || forcedSlow || reduced
            if seek || forcedSlow {
                event = LyricsSprings.slow
            } else if t >= lastEndMs {
                event = LyricsSprings.ended
            } else if rowLine[target] < 0 || (lastScrollTarget >= 0 && rowLine[lastScrollTarget] < 0) {
                event = LyricsSprings.slow
            } else if let first = leaderRows.first, let last = leaderRows.last, target == first || target == last {
                event = LyricsSprings.slow
            } else {
                event = normalSpecFor(target)
            }
            eventStagger = !noStagger
            if forcedSlow { slowUntilNanos = -1 }
        }
        if resizePending {
            resizePending = false
            if event == nil { event = LyricsSprings.slow }
            eventStagger = false
        }

        // 5. Layout.
        if inputsReady {
            let anchorRow = (userScroll ? frozenAnchorRow : target).coerced(in: 0, rowCount - 1)
            let base = anchorY - prefix[anchorRow]
            for r in 0..<rowCount { targetY[r] = base + prefix[r] }
            maxOffset = prefix[anchorRow]
            minOffset = Self.bottomLimitFraction * viewportHeight - (base + prefix[rowCount])
            if minOffset > maxOffset { minOffset = maxOffset }
            if userScroll {
                let clamped = offset.coerced(in: minOffset, maxOffset)
                if clamped != offset { setOffset(clamped) }
            }

            if !laidOut {
                initialLayout(now, target, reduced)
            } else if let event {
                scheduleCascade(now, target, event, stagger: eventStagger && !reduced)
            }
            syncYTargets(now, reduced)
        }
        lastScrollTarget = target

        // 6. Depth: blur, or the alpha falloff without blur.
        updateDepthTargets(now, target, snapChannels)

        // 7. Publish.
        publish(t)
    }

    // MARK: - Internals

    private func layoutInputsReady() -> Bool {
        if viewportHeight <= 0 { return false }
        for r in 0..<rowCount where rowHeight[r] < 0 { return false }
        return true
    }

    private func updateHotSet(_ t: Int64) {
        for k in 0..<hotCount {
            let l = hotList[k]
            lineHot[l] = false
            groupHot[lineGroupLead[l]] = false
        }
        hotCount = 0
        if lineCount == 0 { return }
        var j = Self.upperBound(starts, t &+ Self.leadInMs) - 1
        let minStart = t &- maxLineDurationMs
        while j >= 0 && starts[j] >= minStart {
            if t < ends[j] {
                lineHot[j] = true
                hotList[hotCount] = j
                hotCount += 1
            }
            j -= 1
        }
        for k in 0..<hotCount { groupHot[lineGroupLead[hotList[k]]] = true }
    }

    /// The lowest-index hot lead line; else the interlude containing `t`; else the last line with `start ≤ t` (its
    /// group lead); else line 0's group lead.
    private func resolveScrollTargetRow(_ t: Int64) -> Int {
        var best = Int.max
        for k in 0..<hotCount {
            let l = hotList[k]
            if lineIsLeader[l] && l < best { best = l }
        }
        if best != Int.max { return lineRow[best] }
        for r in interludeRows where t >= rowG0[r] && t < rowG1[r] { return r }
        if lineCount == 0 { return 0 }
        let j = Self.upperBound(starts, t) - 1
        return lineRow[lineGroupLead[j >= 0 ? j : 0]]
    }

    private func normalSpecFor(_ targetRow: Int) -> FloatSpringSpec {
        let ord = rowLeaderOrdinal[targetRow]
        if ord <= 0 { return LyricsSprings.slow }
        let line = rowLine[targetRow]
        let prevLine = rowLine[leaderRows[ord - 1]]
        return LyricsSprings.normal(gapMs: starts[line] &- starts[prevLine])
    }

    private func isRowInViewport(_ row: Int) -> Bool {
        guard row >= 0 && row < rowCount else { return false }
        let top = y.value[row] + offset
        return top >= 0 && top < viewportHeight
    }

    private func snapMarginPx() -> Float { Self.snapMarginDp * config.density }

    private func canSkip(_ row: Int, _ desired: Float) -> Bool {
        let margin = snapMarginPx()
        let h = rowHeight[row].coerced(atLeast: 0)
        let cur = y.value[row] + offset
        let dst = desired + offset
        let bothAbove = cur + h < -margin && dst + h < -margin
        let bothBelow = cur > viewportHeight + margin && dst > viewportHeight + margin
        return bothAbove || bothBelow
    }

    private func initialLayout(_ now: Int64, _ target: Int, _ reduced: Bool) {
        laidOut = true
        let animate = animateInPending && !reduced
        animateInPending = false
        if !animate {
            for r in 0..<rowCount {
                y.snap(r, targetY[r])
                pendingAt[r] = -1
                rowSpec[r] = LyricsSprings.slow
            }
            return
        }
        let margin = snapMarginPx()
        let startY = Self.firstShowStartFactor * viewportHeight
        for r in 0..<rowCount {
            let h = rowHeight[r].coerced(atLeast: 0)
            let offscreen = targetY[r] + h < -margin || targetY[r] > viewportHeight + margin
            y.snap(r, offscreen ? targetY[r] : startY)
        }
        scheduleCascade(now, target, LyricsSprings.slow, stagger: true)
    }

    /// §3.3: sets a pending `(startAt, spec)` per row; `syncYTargets` fires them when due.
    private func scheduleCascade(_ now: Int64, _ target: Int, _ spec: FloatSpringSpec, stagger: Bool) {
        if stagger {
            for r in 0..<rowCount { tops[r] = y.value[r] + offset }
            LyricsCascade.computeDelays(tops: tops, heights: effHeight, count: rowCount, targetRow: target, out: &delays)
        }
        for r in 0..<rowCount {
            let d: Float = stagger ? delays[r] : 0
            // `(d * MS).toLong()`: Float × Long is Float in Kotlin.
            pendingAt[r] = now &+ KotlinMath.toLong(d * Float(Self.ms))
            pendingSpec[r] = spec
        }
    }

    private func syncYTargets(_ now: Int64, _ reduced: Bool) {
        for r in 0..<rowCount {
            let desired = targetY[r]
            if pendingAt[r] >= 0 {
                if now >= pendingAt[r] {
                    let spec = pendingSpec[r] ?? LyricsSprings.slow
                    pendingAt[r] = -1
                    pendingSpec[r] = nil
                    rowSpec[r] = spec
                    retargetY(r, desired, spec, now, reduced)
                }
            } else if abs(y.target[r] - desired) > 0.01 {
                retargetY(r, desired, rowSpec[r] ?? LyricsSprings.slow, now, reduced)
            }
        }
    }

    private func retargetY(_ r: Int, _ desired: Float, _ spec: FloatSpringSpec, _ now: Int64, _ reduced: Bool) {
        if reduced || canSkip(r, desired) { y.snap(r, desired) } else { y.animateTo(r, desired, spec, now) }
    }

    private func stepFling(_ now: Int64) {
        if !flinging { return }
        if flingStartNanos < 0 {
            flingStartNanos = now
            flingDurationNanos = decay.durationNanos(initialValue: flingFrom, initialVelocity: flingVelocity)
        }
        let dt = now &- flingStartNanos
        let raw = decay.valueFromNanos(dt, initialValue: flingFrom, initialVelocity: flingVelocity)
        let clamped = raw.coerced(in: minOffset, maxOffset)
        setOffset(clamped)
        if clamped != raw || dt >= flingDurationNanos {
            flinging = false
            scrollEndedNanos = now
        }
    }

    /// Folds the user offset into the springs and returns to auto-follow.
    private func snapBack() {
        let off = offset
        if off != 0 { for r in 0..<rowCount { y.shift(r, off) } }
        setOffset(0)
        userScroll = false
        setUserScrolling(false)
        dragging = false
        flinging = false
        scrollEndPending = false
        scrollEndedNanos = -1
    }

    private func setOffset(_ value: Float) {
        offset = value
        if scrollOffset != value {
            scrollOffset = value
            changes.insert(.scrollOffset)
        }
    }

    private func setUserScrolling(_ value: Bool) {
        if isUserScrolling != value {
            isUserScrolling = value
            changes.insert(.userScrolling)
        }
    }

    /// Distance d (in lead rows) from the hot lines: rows above the target get `activeIdx − i + 1`, rows below the
    /// last hot lead get `i − lastHotIdx`. Blur is 0 for hot rows, the target, background vocals, interludes, during
    /// user scroll and when disabled.
    private func updateDepthTargets(_ now: Int64, _ target: Int, _ snap: Bool) {
        let cfg = config
        let on = cfg.blurEnabled && !userScroll
        let duration: Int64 = snap ? 0 : (userScroll ? Self.blurDragMs : Self.blurTweenMs)
        let easing: CubicBezierEasing? = userScroll ? nil : Easings.fastOutSlowIn

        let activeOrd: Int
        var lastHotOrd: Int
        if target >= 0 && target < rowCount && rowLine[target] < 0 {
            activeOrd = rowNextLeaderOrdinal[target]
            lastHotOrd = activeOrd - 1
        } else {
            activeOrd = (target >= 0 && target < rowCount) ? Swift.max(rowLeaderOrdinal[target], 0) : 0
            lastHotOrd = activeOrd
            for k in 0..<hotCount {
                let l = hotList[k]
                if lineIsLeader[l] { lastHotOrd = Swift.max(lastHotOrd, rowLeaderOrdinal[lineRow[l]]) }
            }
        }

        for r in 0..<rowCount {
            let ord = rowLeaderOrdinal[r]
            var d = 0
            if on && ord >= 0 && r != target && !lineHot[rowLine[r]] {
                if ord < activeOrd {
                    d = activeOrd - ord + 1
                } else if ord > lastHotOrd {
                    d = ord - lastHotOrd
                } else {
                    d = 1
                }
            }
            let sigmaTarget = cfg.blurSupported ? LyricsBlurMath.depthSigmaDp(distance: d, strength: cfg.blurStrength) : 0
            let alphaTarget = cfg.blurSupported ? 1 : LyricsBlurMath.fallbackAlphaFactor(distance: d)
            sigma.animateTo(r, sigmaTarget, duration, easing, now)
            depthAlpha.animateTo(r, alphaTarget, duration, easing, now)
        }
    }

    @inline(__always)
    private func mark(_ r: Int, _ change: LyricRowChange) {
        if rowChanges[r].isEmpty { changedRows.append(r) }
        rowChanges[r].insert(change)
    }

    /// Android `writeFloat`: write when the value moved by at least `eps`, or settled on a different value.
    @inline(__always)
    private func write(_ outputs: inout [Float], _ r: Int, _ v: Float, _ eps: Float, _ settled: Bool,
                       _ change: LyricRowChange) {
        let old = outputs[r]
        if abs(v - old) >= eps || (settled && v != old) {
            outputs[r] = v
            mark(r, change)
        }
    }

    private func publish(_ t: Int64) {
        let density = config.density
        let quantum = config.blurSigmaQuantum
        var moving = flinging || dragging || userScroll || tapPending || resizePending
        for r in 0..<rowCount {
            let line = rowLine[r]
            let isBg = rowIsBg[r]
            let bgP = bgExpand.value[r].coerced(in: 0, 1)

            // y (+ background slide)
            var yv = y.value[r]
            if isBg && yv < Self.offscreenY / 2 {
                let h = rowHeight[r].coerced(atLeast: 0)
                let dir: Float = rowBgAbove[r] ? 1 : -1
                yv += (1 - bgP) * dir * Self.backgroundSlideFraction * h
            }
            let ySettled = !y.active[r] && !bgExpand.active[r]
            write(&rowY, r, yv, Self.yEps, ySettled, .y)

            // scale
            let sv: Float
            if line < 0 {
                sv = 1
            } else if isBg {
                if bgP < 0.001 && !bgExpand.active[r] && !groupHot[lineGroupLead[line]] {
                    sv = Self.backgroundCollapsedScale
                } else {
                    sv = Self.backgroundExpandFromScale + (1 - Self.backgroundExpandFromScale) * bgP
                }
            } else {
                sv = scale.value[r]
            }
            write(&rowScale, r, sv, Self.scaleEps, !scale.active[r] && !bgExpand.active[r], .scale)

            // blur, quantised (Android radius and iOS σ)
            let s = sigma.value[r]
            let radius = s > 0 ? LyricsBlurMath.quantizeRadiusPx(LyricsBlurMath.sigmaDpToRadiusPx(s, density: density)) : 0
            let sigmaOut = s > 0 ? LyricsBlurMath.quantizeSigma(s, quantum: quantum) : 0
            if radius != rowBlurRadiusPx[r] || sigmaOut != rowBlurSigma[r] {
                rowBlurRadiusPx[r] = radius
                rowBlurSigma[r] = sigmaOut
                mark(r, .blur)
            }
            write(&rowDepthAlpha, r, depthAlpha.value[r], Self.activenessEps, !depthAlpha.active[r], .depthAlpha)

            // activeness, hot
            if line >= 0 {
                write(&rowActiveness, r, activeness.value[r], Self.activenessEps, !activeness.active[r], .activeness)
            }
            let hot = line >= 0 ? lineHot[line] : InterludeTimeline.isActive(tMs: t, g0: rowG0[r], g1: rowG1[r])
            if hot != rowHot[r] {
                rowHot[r] = hot
                mark(r, .hot)
            }
            if line >= 0 && !rowPrefetch[r] && t &+ Self.leadInMs &+ Self.prefetchLeadMs >= starts[line] && t < ends[line] {
                rowPrefetch[r] = true
                mark(r, .prefetch)
            }

            // expand, presence
            let ex: Float
            if line < 0 {
                ex = InterludeTimeline.expand(tMs: t, g0: rowG0[r], g1: rowG1[r])
            } else if isBg {
                ex = bgP
            } else {
                ex = 1
            }
            write(&rowExpand, r, ex, Self.expandEps, line < 0 || !bgExpand.active[r], .expand)
            let pr: Float = isBg ? presence.value[r] : 1
            write(&rowPresence, r, pr, Self.activenessEps, !presence.active[r], .presence)

            if y.active[r] || scale.active[r] || bgExpand.active[r] || activeness.active[r] || presence.active[r]
                || sigma.active[r] || depthAlpha.active[r] || pendingAt[r] >= 0 {
                moving = true
            }
        }
        if !laidOut && layoutInputsReady() { moving = true }
        isAtRest = !moving
    }

    // MARK: - Test / debug accessors

    public func rowTargetY(_ row: Int) -> Float { targetY[row] }
    public func rowSpringY(_ row: Int) -> Float { y.value[row] }
    public func rowPendingAtNanos(_ row: Int) -> Int64 { pendingAt[row] }
    public func isLineHot(_ line: Int) -> Bool { lineHot[line] }
    public func rowSigmaTargetDp(_ row: Int) -> Float { sigma.to[row] }
    public var isLaidOut: Bool { laidOut }
}
