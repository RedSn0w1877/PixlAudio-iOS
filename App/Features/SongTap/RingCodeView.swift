import PixlLibrary
import SwiftUI

// The Pixl ring code, drawn (Android `RingCodeView.kt`).
//
// One pre-built geometry per size (the 200 dot centres, the big and the small dots as two flat paths), drawn by a single `Canvas`:
// the idle sway, the approach and the beam are `RingCodeTimeline.frame` read once per drawn frame (a few integer operations), so a
// frame is two path fills and a handful of shapes, with no layout pass and no blur. While the beam plays each dot is drawn on its own
// (200 circles, 2 seconds). The `TimelineView` that feeds it ticks at about 30 frames a second while the code idles (the sway is slow),
// at the display's rate while a beam plays, and not at all while the code is off screen, the app is in the background, or Reduce
// Motion is on and nothing is beaming.
//
// The code itself is flat: a plain plate and plain round dots, never glass, so the other phone's camera can read it. The dots are the
// app's accent colour (darkened only as far as the 7:1 contrast rule needs) and the plate its lighter tint (tone 95), both from
// PixlCore's `RingCodeStyle`; the start dot is the one fixed orange.

/// The 200 slot bits of one ring code (0 = small dot, 1 = big dot, index = slot id) and a serial that changes with every new code.
nonisolated struct RingCodeSlots: Equatable, Sendable {
    let bits: [UInt8]
    let serial: Int

    nonisolated static func == (a: RingCodeSlots, b: RingCodeSlots) -> Bool { a.serial == b.serial }
}

/// The palette of an accent colour, worked out once per colour (it is a few colour-space conversions, not something to do per frame).
@MainActor
enum RingPalettes {
    private static var cache: [UInt32: RingCodeStyle.Palette] = [:]

    static func palette(for accentArgb: UInt32) -> RingCodeStyle.Palette {
        if let known = cache[accentArgb] { return known }
        let made = RingCodeStyle.palette(accentArgb)
        cache[accentArgb] = made
        return made
    }
}

/// Where every slot sits in the ring and in its ring, so the beam can ask the timeline about a dot without any search.
private nonisolated enum RingSlotTables {
    static let ring: [Int] = (0..<RingCodeLayout.slots).map { RingCodeLayout.ringOf($0) }
    static let index: [Int] = (0..<RingCodeLayout.slots).map { RingCodeLayout.indexInRing($0) }
    /// Clockwise from 12 o'clock.
    static let angle: [Double] = (0..<RingCodeLayout.slots).map {
        Double(RingCodeLayout.indexInRing($0)) / Double(RingCodeLayout.ringSlots[RingCodeLayout.ringOf($0)]) * 2 * Double.pi
    }
}

/// The geometry of one code at one size, built once: dot centres relative to the plate's centre, in points.
private final class RingGeometry {
    let half: CGFloat
    let serial: Int
    let slotX: [CGFloat]
    let slotY: [CGFloat]
    let slotR: [CGFloat]
    let big: Path
    let small: Path

    init(half: CGFloat, slots: RingCodeSlots) {
        self.half = half
        serial = slots.serial
        let unit = half / 1000
        var xs = [CGFloat](repeating: 0, count: RingCodeLayout.slots)
        var ys = xs
        var rs = xs
        var bigPath = Path()
        var smallPath = Path()
        let bigR = CGFloat(RingCodeLayout.bigRadius) * unit
        let smallR = CGFloat(RingCodeLayout.smallRadius) * unit
        for slot in 0..<RingCodeLayout.slots {
            let r = CGFloat(RingCodeLayout.ringRadius[RingSlotTables.ring[slot]]) * unit
            let a = RingSlotTables.angle[slot]
            let x = r * CGFloat(sin(a))
            let y = -r * CGFloat(cos(a))
            rs[slot] = r
            xs[slot] = x
            ys[slot] = y
            if slots.bits[slot] != 0 {
                bigPath.addEllipse(in: CGRect(x: x - bigR, y: y - bigR, width: bigR * 2, height: bigR * 2))
            } else {
                smallPath.addEllipse(in: CGRect(x: x - smallR, y: y - smallR, width: smallR * 2, height: smallR * 2))
            }
        }
        slotX = xs
        slotY = ys
        slotR = rs
        big = bigPath
        small = smallPath
    }
}

/// Holds the geometry between frames (a reference, so drawing a frame never copies it).
private final class RingGeometryCache {
    private var current: RingGeometry?

    func geometry(for slots: RingCodeSlots, half: CGFloat) -> RingGeometry {
        if let current, current.serial == slots.serial, abs(current.half - half) < 0.5 { return current }
        let made = RingGeometry(half: half, slots: slots)
        current = made
        return made
    }
}

struct RingCodeView<Art: View>: View {
    let slots: RingCodeSlots
    let palette: RingCodeStyle.Palette
    /// The Bluetooth side's "the other phone is near" level, 0...500 (nil for none).
    var approach: SongTapGlowModel?
    /// When the beam began (wall clock, epoch milliseconds), 0 for none.
    var beamStartMs: Int64 = 0
    /// The height of the screen the art flies across (the art's own size times four when unknown).
    var rootHeight: CGFloat = 0
    var pillText: String?
    /// Nil follows the system's Reduce Motion.
    var reduced: Bool?
    let art: Art

    init(slots: RingCodeSlots, palette: RingCodeStyle.Palette, approach: SongTapGlowModel? = nil, beamStartMs: Int64 = 0,
         rootHeight: CGFloat = 0, pillText: String? = nil, reduced: Bool? = nil, @ViewBuilder art: () -> Art) {
        self.slots = slots
        self.palette = palette
        self.approach = approach
        self.beamStartMs = beamStartMs
        self.rootHeight = rootHeight
        self.pillText = pillText
        self.reduced = reduced
        self.art = art()
    }

    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownAt = Date()
    @State private var cache = RingGeometryCache()
    @State private var visible = false
    @State private var near = false
    @State private var approachStartMs = RingCodeTimeline.none
    @State private var approachEndMs = RingCodeTimeline.none

    private static var nearEnter: Int { 170 }
    private static var nearExit: Int { 90 }
    private static var spiralTurns: CGFloat { 0.32 }

    var body: some View {
        let beaming = beamStartMs != 0
        let isReduced = reduced ?? reduceMotion
        let running = visible && scenePhase == .active && (!isReduced || beaming)
        let shownMs = Int64(shownAt.timeIntervalSince1970 * 1000)
        let beamAt = beaming ? beamStartMs - shownMs : RingCodeTimeline.none
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: beaming ? nil : 1.0 / 30.0, paused: !running)) { timeline in
                let tMs = Int64(timeline.date.timeIntervalSince(shownAt) * 1000)
                let frame = RingCodeTimeline.frame(tMs: tMs, approachStartMs: approachStartMs, approachEndMs: approachEndMs,
                                                   beamStartMs: beamAt, reducedMotion: isReduced)
                ZStack {
                    Canvas { canvas, size in draw(&canvas, size, frame) }
                    artDisc(frame, side: side)
                    if let pillText { pill(pillText, frame) }
                }
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            visible = true
            shownAt = Date()
        }
        .onDisappear { visible = false }
        // "The other phone is near", with hysteresis, as the two moments the timeline wants.
        .onChange(of: approach?.value ?? 0) { _, level in
            let t = Int64(Date().timeIntervalSince(shownAt) * 1000)
            if !near && level >= Self.nearEnter {
                near = true
                approachStartMs = t
                approachEndMs = RingCodeTimeline.none
            } else if near && level <= Self.nearExit {
                near = false
                approachEndMs = t
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SongTapStrings.ringDescription)
        .accessibilityIdentifier("songTap.ringCode")
    }

    // MARK: Pieces

    /// The album art in the middle, clipped to a circle: it breathes, pulses, lifts and leaves through the top with the beam.
    private func artDisc(_ frame: RingFrameBuffer, side: CGFloat) -> some View {
        let discSide = side * CGFloat(RingCodeLayout.artRadius * 2) / 1000
        return art
            .frame(width: discSide, height: discSide)
            .background(theme.surfaceContainerHighest)
            .clipShape(Circle())
            .scaleEffect(CGFloat(frame.artScale) / 1000)
            .offset(y: CGFloat(frame.artTranslateY) / 1000 * (rootHeight > 0 ? rootHeight : side * 4))
            .opacity(Double(frame.artAlpha) / 1000)
    }

    private func pill(_ text: String, _ frame: RingFrameBuffer) -> some View {
        Text(text)
            .pixlFont(.labelLarge)
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.primaryContainer, in: Capsule())
            .opacity(Double(frame.pillAlpha) / 1000)
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ frame: RingFrameBuffer) {
        let half = min(size.width, size.height) / 2
        guard half > 1 else { return }
        let unit = half / 1000
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let geometry = cache.geometry(for: slots, half: half)
        let dot = Color(argb: palette.dot)
        let plate = Color(argb: palette.plate)
        let marker = Color(argb: palette.marker)

        if frame.glow > 0 {
            let reach = half * 1.3
            var glow = context
            glow.opacity = Double(frame.glow) / 1000
            glow.fill(Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)),
                      with: .radialGradient(Gradient(colors: [dot.opacity(0.55), dot.opacity(0)]), center: centre, startRadius: 0,
                                            endRadius: reach))
        }
        if frame.plateAlpha > 0 {
            var plateContext = context
            plateContext.opacity = Double(frame.plateAlpha) / 1000
            let square = CGRect(x: centre.x - half, y: centre.y - half, width: half * 2, height: half * 2)
            plateContext.fill(Path(roundedRect: square, cornerRadius: CGFloat(RingCodeLayout.plateCorner) * unit, style: .continuous),
                              with: .color(plate))
        }
        let alpha = Double(frame.codeAlpha) / 1000
        guard alpha > 0 else { return }

        var code = context
        code.translateBy(x: centre.x, y: centre.y)
        code.rotate(by: .radians(Double(frame.codeAngle) / 1_000_000))
        let scale = CGFloat(frame.codeScale) / 1000
        code.scaleBy(x: scale, y: scale)

        if frame.plateAlpha > 0 {
            var outline = code
            outline.opacity = alpha * Double(frame.plateAlpha) / 1000
            let radius = CGFloat(RingCodeLayout.bezelOuter + RingCodeLayout.bezelInner) / 2 * unit
            outline.stroke(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)), with: .color(dot),
                           lineWidth: CGFloat(RingCodeLayout.bezelOuter - RingCodeLayout.bezelInner) * unit)
        }

        let markerCentre = CGPoint(x: 0, y: -CGFloat(RingCodeLayout.markerRadiusAt) * unit)
        let markerR = CGFloat(RingCodeLayout.markerRadius) * unit
        if frame.beamMs < 0 {
            // At rest: all big dots in one fill, all small dots in another.
            code.opacity = alpha
            code.fill(geometry.big, with: .color(dot))
            code.fill(geometry.small, with: .color(dot))
            code.fill(Path(ellipseIn: CGRect(x: markerCentre.x - markerR, y: markerCentre.y - markerR, width: markerR * 2, height: markerR * 2)),
                      with: .color(marker))
            return
        }
        // The beam: each dot peels off and spirals into the art.
        let bigR = CGFloat(RingCodeLayout.bigRadius) * unit
        let smallR = CGFloat(RingCodeLayout.smallRadius) * unit
        let artEdge = CGFloat(RingCodeLayout.artRadius) * unit * 0.8
        let turn = Self.spiralTurns * 2 * CGFloat.pi
        for slot in 0..<RingCodeLayout.slots {
            let p = RingCodeTimeline.slotProgress(ring: RingSlotTables.ring[slot], index: RingSlotTables.index[slot], beamMs: frame.beamMs)
            if p >= 1000 { continue }
            let isBig = slots.bits[slot] != 0
            let r = isBig ? bigR : smallR
            if p == 0 {
                code.opacity = alpha
                code.fill(Path(ellipseIn: CGRect(x: geometry.slotX[slot] - r, y: geometry.slotY[slot] - r, width: r * 2, height: r * 2)),
                          with: .color(dot))
                continue
            }
            let e = CGFloat(SongTapTimeline.smooth(p)) / 1000
            let radius = geometry.slotR[slot] + (artEdge - geometry.slotR[slot]) * e
            let angle = CGFloat(RingSlotTables.angle[slot]) + turn * e
            let shrunk = r * (1 - 0.35 * e)
            let fade: Double = p < 650 ? 1 : 1 - Double(p - 650) / 350
            code.opacity = alpha * fade
            let x = radius * CGFloat(sin(angle))
            let y = -radius * CGFloat(cos(angle))
            code.fill(Path(ellipseIn: CGRect(x: x - shrunk, y: y - shrunk, width: shrunk * 2, height: shrunk * 2)), with: .color(dot))
        }
        let mp = RingCodeTimeline.markerProgress(beamMs: frame.beamMs)
        if mp < 1000 {
            let e = CGFloat(SongTapTimeline.smooth(mp)) / 1000
            let from = -markerCentre.y
            let radius = from + (artEdge - from) * e
            let angle = turn * e
            let shrunk = markerR * (1 - 0.35 * e)
            code.opacity = alpha * (mp < 650 ? 1 : 1 - Double(mp - 650) / 350)
            let x = radius * CGFloat(sin(angle))
            let y = -radius * CGFloat(cos(angle))
            code.fill(Path(ellipseIn: CGRect(x: x - shrunk, y: y - shrunk, width: shrunk * 2, height: shrunk * 2)), with: .color(marker))
        }
    }
}
