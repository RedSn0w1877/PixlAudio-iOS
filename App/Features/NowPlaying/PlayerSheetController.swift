import Observation
import SwiftUI
import UIKit

/// The player sheet's state (Android `PlayerSheetState` + `SheetMotionController` + the drag handler of
/// `UnifiedPlayerSheetV2`): one card that morphs from the mini player into the full player.
///
/// `expansion` is the sheet's expansion fraction (0 = mini player, 1 = full player). While a finger drags it is set
/// directly, every touch event, with animations disabled; on release it springs to 0 or 1. Only the host and the
/// small fade modifiers read it (each its own `Animatable` modifier, interpolated by the same spring — nothing is
/// written into the environment every frame), never the player's content, so a drag never re-renders the full
/// player.
///
/// The full player is built once — ahead of time (`prewarm`, a second after the mini player appears), or by the
/// first expand / drag — and then kept, hidden while collapsed, so later expands don't rebuild it inside their first
/// frames.
@Observable
final class PlayerSheetController {
    /// Android `PlayerSheetState.EXPANDED` (the target the sheet rests at).
    private(set) var isExpanded = false
    /// The current expansion fraction (0…1).
    var expansion: CGFloat = 0
    /// The mini player's slot in global coordinates (reported by `MiniPlayerSlot`); nil while the shell hides it
    /// (keyboard up, nothing playing).
    private(set) var collapsedFrame: CGRect?
    /// The slot's bottom corners (32 pt: the mini player floats as its own capsule above the tab bar).
    private(set) var collapsedBottomRadius: CGFloat = Tokens.Shell.navBarCornerRadius
    /// A finger is moving the sheet (Android `isDragging`).
    var isDragging = false
    /// The seek bar is being scrubbed: the sheet's drag gesture stands aside (Android consumes vertical drags in
    /// the progress section).
    @ObservationIgnored var isScrubbing = false
    /// Android `visualOvershootScaleY`: the squash on collapse (0.96 → 1, bouncy) and the bump on expand.
    var overshootScaleY: CGFloat = 1
    /// The keyboard is up and the shell's bars have stepped aside: the collapsed card slides down with the tab bar
    /// (set by the shell in the same animation), keeping its slot so it comes back without a rebuild.
    var hiddenForKeyboard = false
    /// The full player has been built and stays mounted (hidden while collapsed).
    private(set) var hasBuiltFullPlayer = false
    /// The first expand waits one frame for the full player to mount at progress 0 (its fades must interpolate).
    @ObservationIgnored private var pendingExpandVelocity: Double?
    /// A collapse that navigates afterwards is under way (repeat taps are dropped, like Android's job check).
    @ObservationIgnored private var isNavigatingAfterCollapse = false

    // MARK: Slot

    func updateSlot(frame: CGRect, bottomRadius: CGFloat) {
        if collapsedFrame != frame { collapsedFrame = frame }
        if collapsedBottomRadius != bottomRadius { collapsedBottomRadius = bottomRadius }
    }

    func removeSlot() {
        // The slot leaves while the keyboard is up; the card keeps its frame and slides out with the bar instead.
        guard !hiddenForKeyboard else { return }
        collapsedFrame = nil
    }

    // MARK: Commands

    /// Builds the full player ahead of its first expand (hidden; see `FullPlayerLayer`).
    func prewarm() {
        if !hasBuiltFullPlayer { hasBuiltFullPlayer = true }
    }

    /// Nothing is loaded any more: the card goes, and so does the built full player (the next song pre-warms again).
    func resetFullPlayer() {
        pendingExpandVelocity = nil
        if hasBuiltFullPlayer { hasBuiltFullPlayer = false }
    }

    /// Expands to the full player (Android `expandPlayerSheet`). `animated: false` for launch states.
    func expand(animated: Bool = true, initialVelocity: Double = 0) {
        // VoiceOver: once the full player is past half way (it stays hidden from accessibility below 0.5), move
        // focus to it — the mini player that had focus is gone.
        if !isExpanded { postScreenChanged(after: animated ? 0.45 : 0.05) }
        guard animated else {
            // One transaction: a full player built here is inserted by the same update that sets the expansion, so
            // its fades read 1 on their first pass. Set in steps, `withoutAnimation` first applied the pending build
            // as an update of its own, and the fades of the player it inserted sometimes missed the expansion set
            // right after: the full player stayed invisible over its background (5–11 % of launches straight into
            // the expanded player on CI, never on main; docs/performance.md).
            withoutAnimation {
                isExpanded = true
                if !hasBuiltFullPlayer { hasBuiltFullPlayer = true }
                expansion = 1
            }
            return
        }
        isExpanded = true
        guard hasBuiltFullPlayer else {
            // Not pre-warmed yet: mount the full player first (in the expand's transaction, as its insertion used to
            // be) and start the spring when it appears, so its fades start from 0.
            pendingExpandVelocity = initialVelocity
            withAnimation(PlayerSheetMotion.expand(initialVelocity: initialVelocity)) { hasBuiltFullPlayer = true }
            return
        }
        startExpand(initialVelocity: initialVelocity)
    }

    /// The full player is on screen: starts an expand that waited for it — on the next main-actor turn, once the
    /// update that inserted the player has been applied in full (an expansion changed while that update is still
    /// under way can be missed by the new player's fades; see `expand(animated: false)`).
    func fullPlayerDidAppear() {
        guard let velocity = pendingExpandVelocity else { return }
        pendingExpandVelocity = nil
        Task { [weak self] in
            guard let self, self.isExpanded, self.expansion < 1 else { return }
            self.startExpand(initialVelocity: velocity)
        }
    }

    private func startExpand(initialVelocity: Double) {
        // Reduce Motion: a short ease, without the spring's travel or the scale bump.
        if PixlAccessibility.reducesMotion {
            withAnimation(PlayerSheetMotion.reducedMotion) { expansion = 1 }
            return
        }
        withAnimation(PlayerSheetMotion.expand(initialVelocity: initialVelocity)) { expansion = 1 }
        // Android's expand bump: scaleY 1 → 1.05 → 1 over 250 ms.
        withAnimation(.easeOut(duration: 0.125)) { overshootScaleY = 1.05 }
        withAnimation(.easeIn(duration: 0.125).delay(0.125)) { overshootScaleY = 1 }
    }

    /// Collapses, then runs `action` once the sheet has collapsed to `threshold` (Android
    /// `triggerAlbumNavigationFromPlayer`: navigate after the collapse, not in the same frame, so the push and the
    /// collapse don't compete for the same frames). Taps while it waits are dropped.
    func collapse(thenAfterReaching threshold: CGFloat = 0.1, _ action: @escaping @MainActor @Sendable () -> Void) {
        guard !isNavigatingAfterCollapse else { return }
        let delay = PlayerSheetMotion.collapseTime(toReach: threshold, fromFraction: expansion)
        collapse()
        isNavigatingAfterCollapse = true
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.isNavigatingAfterCollapse = false
            action()
        }
    }

    /// Collapses to the mini player (Android `collapsePlayerSheet`), with the bouncy squash.
    func collapse(animated: Bool = true, initialVelocity: Double = 0) {
        let from = expansion
        let wasExpanded = isExpanded
        pendingExpandVelocity = nil
        isExpanded = false
        if wasExpanded { postScreenChanged(after: animated ? 0.35 : 0.05) }
        guard animated else {
            withoutAnimation { expansion = 0 }
            return
        }
        // Reduce Motion: a short ease back, without the squash and its slow wobble.
        if PixlAccessibility.reducesMotion {
            withoutAnimation { overshootScaleY = 1 }
            withAnimation(PlayerSheetMotion.reducedMotion) { expansion = 0 }
            return
        }
        withAnimation(PlayerSheetMotion.collapse(fromFraction: from, initialVelocity: initialVelocity)) {
            expansion = 0
        }
        // Android `collapseInitialSquashForFraction` then a medium-bouncy, very-low-stiffness spring back to 1.
        withoutAnimation { overshootScaleY = PlayerSheetMotion.collapseSquash(fromFraction: from) }
        withAnimation(PlayerSheetMotion.squashRelease) { overshootScaleY = 1 }
    }

    func toggle() {
        isExpanded ? collapse() : expand()
    }

    /// Tells VoiceOver the screen changed once the sheet has (nearly) settled; nothing when VoiceOver is off.
    private func postScreenChanged(after delay: Double) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            PixlAccessibility.screenChanged()
        }
    }

    // MARK: Drag (Android `SheetVerticalDragGestureHandler`)

    @ObservationIgnored private var dragStartExpansion: CGFloat = 0
    @ObservationIgnored private var dragAccumulatedY: CGFloat = 0

    func beginDrag() {
        dragStartExpansion = expansion
        dragAccumulatedY = 0
        if !hasBuiltFullPlayer { hasBuiltFullPlayer = true }
        if !isDragging { isDragging = true }
    }

    /// `translationY` is the finger's travel since the drag began (down = positive); `distance` is the travel
    /// between the collapsed and the expanded position.
    func drag(translationY: CGFloat, distance: CGFloat) {
        dragAccumulatedY = translationY
        let fraction = PlayerSheetDragMath.expansionFraction(start: dragStartExpansion, translationY: translationY,
                                                            distance: distance)
        withoutAnimation { expansion = fraction }
    }

    /// Settles the sheet (Android `resolveVerticalSheetTargetState`); `velocityY` in points per second.
    func endDrag(velocityY: CGFloat, distance: CGFloat) {
        isDragging = false
        let expand = PlayerSheetDragMath.resolvesExpanded(wasExpanded: isExpanded, accumulatedDragY: dragAccumulatedY,
                                                          velocityY: velocityY, fraction: expansion)
        // Velocity in fractions per second for the spring (Android `initialVelocity / velocityScale`).
        let fractionVelocity = distance > 0 ? Double(-velocityY / distance) : 0
        if expand {
            self.expand(initialVelocity: fractionVelocity)
        } else {
            collapse(initialVelocity: fractionVelocity)
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// Android's sheet springs: `MotionScheme.expressive().defaultSpatialSpec` (damping 0.8, stiffness 380) to expand;
/// on collapse a low-stiffness spring whose damping goes from no-bounce to low-bouncy with the fraction it starts
/// from (`collapseSpringDampingForFraction`). Stiffness/damping map 1:1 (unit mass), so the motion is the same.
nonisolated enum PlayerSheetMotion {
    /// Expand and collapse under Reduce Motion: no overshoot, no squash, no wobble (docs/design.md: "no swell,
    /// short ease").
    static var reducedMotion: Animation { .easeInOut(duration: 0.25) }

    static func expand(initialVelocity: Double) -> Animation {
        spring(stiffness: 380, dampingRatio: 0.8, initialVelocity: initialVelocity)
    }

    static func collapse(fromFraction fraction: CGFloat, initialVelocity: Double) -> Animation {
        let ratio = 1.0 + (0.75 - 1.0) * Double(min(max(fraction, 0), 1))
        return spring(stiffness: 200, dampingRatio: ratio, initialVelocity: initialVelocity)
    }

    /// `collapseInitialSquashForFraction`: lerp(1, 0.97, fraction).
    static func collapseSquash(fromFraction fraction: CGFloat) -> CGFloat {
        1 + (0.97 - 1) * min(max(fraction, 0), 1)
    }

    /// `spring(DampingRatioMediumBouncy, StiffnessVeryLow)`.
    static let squashRelease = spring(stiffness: 50, dampingRatio: 0.5, initialVelocity: 0)

    /// Seconds until the collapse spring started at rest from `fromFraction` first reaches `threshold` (the closed
    /// form of the spring's step response, stiffness 200, damping ratio from the start fraction), capped at 0.8 s
    /// (Android waits for `expansion <= 0.1` with an 800 ms timeout). 0 when already there.
    static func collapseTime(toReach threshold: CGFloat, fromFraction fraction: CGFloat) -> Double {
        let from = Double(min(max(fraction, 0), 1))
        let target = Double(threshold)
        guard from > target, from > 0 else { return 0 }
        let omega = 200.0.squareRoot()
        let zeta = 1.0 + (0.75 - 1.0) * from
        // y(t): remaining share of the travel, 1 at t = 0; the sheet is at `from * y(t)`.
        let goal = target / from
        let step = 0.001
        var t = 0.0
        while t < 0.8 {
            t += step
            let y: Double
            if zeta < 1 {
                let damped = omega * (1 - zeta * zeta).squareRoot()
                y = exp(-zeta * omega * t) * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
            } else {
                y = exp(-omega * t) * (1 + omega * t)
            }
            if y <= goal { return t }
        }
        return 0.8
    }

    private static func spring(stiffness: Double, dampingRatio: Double, initialVelocity: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * dampingRatio * stiffness.squareRoot(),
                             initialVelocity: initialVelocity)
    }
}

/// Pure sheet-drag maths, ported from `SheetVerticalDragMath.kt` (1 dp = 1 pt; Android's velocity threshold of
/// 150 px/s is about 55 pt/s at the reference phone's density).
nonisolated enum PlayerSheetDragMath {
    static let minDragThreshold: CGFloat = 5
    static let velocityThreshold: CGFloat = 55

    /// `sheetDragExpansionFraction`: the start fraction plus the share of the travel the finger covered.
    static func expansionFraction(start: CGFloat, translationY: CGFloat, distance: CGFloat) -> CGFloat {
        let denominator = max(distance, 1)
        return min(max(start - translationY / denominator, 0), 1)
    }

    /// `resolveVerticalSheetTargetState`.
    static func resolvesExpanded(wasExpanded: Bool, accumulatedDragY: CGFloat, velocityY: CGFloat,
                                 fraction: CGFloat) -> Bool {
        if wasExpanded && accumulatedDragY <= 0 { return true }
        if abs(accumulatedDragY) > minDragThreshold { return accumulatedDragY < 0 }
        if abs(velocityY) > velocityThreshold { return velocityY < 0 }
        return fraction > 0.5
    }
}

/// What the sheet's layers derive from the expansion fraction (each fade modifier interpolates its own copy).
nonisolated struct PlayerSheetMetrics: Equatable, Sendable {
    /// Expansion fraction, 0…1.
    var progress: CGFloat = 1
    /// The card's leading edge in screen points (the full player stays put horizontally inside the card).
    var cardMinX: CGFloat = 0

    /// Android `FullPlayerVisualState.contentAlpha`: invisible until 25 % expanded.
    var fullPlayerAlpha: CGFloat { min(max(progress - 0.25, 0), 0.75) / 0.75 }
    /// The mini player fades out over the first half.
    var miniPlayerAlpha: CGFloat { min(max(1 - progress * 2, 0), 1) }

    /// Android `DelayedContent.baseAlphaProvider` for a section starting at `start`.
    func sectionAlpha(start: CGFloat) -> CGFloat {
        min(max((progress - start) / max(1 - start, 0.001), 0), 1)
    }
}

/// Fades a full-player section in like Android's `DelayedContent` (`normalStartThreshold`), reading the sheet's
/// progress in this small modifier only — the section itself is not re-evaluated while the sheet moves. The value is
/// interpolated by `PlayerSectionFadeEffect` with the same spring as the card, frame by frame.
struct PlayerSectionFade: ViewModifier {
    let start: CGFloat
    var slide: CGFloat = 0

    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.modifier(PlayerSectionFadeEffect(progress: env.playerSheet.expansion, start: start, slide: slide))
    }
}

struct PlayerSectionFadeEffect: ViewModifier, Animatable {
    nonisolated var animatableData: CGFloat
    let start: CGFloat
    let slide: CGFloat

    init(progress: CGFloat, start: CGFloat, slide: CGFloat) {
        animatableData = progress
        self.start = start
        self.slide = slide
    }

    func body(content: Content) -> some View {
        let metrics = PlayerSheetMetrics(progress: min(max(animatableData, 0), 1))
        content
            .opacity(metrics.sectionAlpha(start: start))
            .offset(y: slide * (1 - metrics.progress))
    }
}

extension View {
    func playerSectionFade(start: CGFloat, slide: CGFloat = 0) -> some View {
        modifier(PlayerSectionFade(start: start, slide: slide))
    }
}
