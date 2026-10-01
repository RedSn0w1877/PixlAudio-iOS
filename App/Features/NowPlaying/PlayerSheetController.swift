import Observation
import SwiftUI

/// The player sheet's state (Android `PlayerSheetState` + `SheetMotionController` + the drag handler of
/// `UnifiedPlayerSheetV2`): one card that morphs from the mini player into the full player.
///
/// `expansion` is the sheet's expansion fraction (0 = mini player, 1 = full player). While a finger drags it is set
/// directly, every touch event, with animations disabled; on release it springs to 0 or 1. Only the host and the
/// small fade modifiers read it (through `PlayerSheetMetrics` in the environment), never the player's content, so a
/// drag never re-renders the full player.
@Observable
final class PlayerSheetController {
    /// Android `PlayerSheetState.EXPANDED` (the target the sheet rests at).
    private(set) var isExpanded = false
    /// The current expansion fraction (0…1).
    var expansion: CGFloat = 0
    /// The mini player's slot in global coordinates (reported by `MiniPlayerSlot`); nil while the shell hides it
    /// (keyboard up, nothing playing).
    private(set) var collapsedFrame: CGRect?
    /// The slot's bottom corners: 10 pt where the mini player sits on the bottom bar, 32 pt when it is alone.
    private(set) var collapsedBottomRadius: CGFloat = Tokens.Shell.joinCornerRadius
    /// A finger is moving the sheet (Android `isDragging`).
    var isDragging = false
    /// The seek bar is being scrubbed: the sheet's drag gesture stands aside (Android consumes vertical drags in
    /// the progress section).
    @ObservationIgnored var isScrubbing = false
    /// Android `visualOvershootScaleY`: the squash on collapse (0.96 → 1, bouncy) and the bump on expand.
    var overshootScaleY: CGFloat = 1

    // MARK: Slot

    func updateSlot(frame: CGRect, bottomRadius: CGFloat) {
        if collapsedFrame != frame { collapsedFrame = frame }
        if collapsedBottomRadius != bottomRadius { collapsedBottomRadius = bottomRadius }
    }

    func removeSlot() {
        collapsedFrame = nil
    }

    // MARK: Commands

    /// Expands to the full player (Android `expandPlayerSheet`). `animated: false` for launch states.
    func expand(animated: Bool = true, initialVelocity: Double = 0) {
        isExpanded = true
        guard animated else {
            withoutAnimation { expansion = 1 }
            return
        }
        withAnimation(PlayerSheetMotion.expand(initialVelocity: initialVelocity)) { expansion = 1 }
        // Android's expand bump: scaleY 1 → 1.05 → 1 over 250 ms.
        withAnimation(.easeOut(duration: 0.125)) { overshootScaleY = 1.05 }
        withAnimation(.easeIn(duration: 0.125).delay(0.125)) { overshootScaleY = 1 }
    }

    /// Collapses to the mini player (Android `collapsePlayerSheet`), with the bouncy squash.
    func collapse(animated: Bool = true, initialVelocity: Double = 0) {
        let from = expansion
        isExpanded = false
        guard animated else {
            withoutAnimation { expansion = 0 }
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

    // MARK: Drag (Android `SheetVerticalDragGestureHandler`)

    @ObservationIgnored private var dragStartExpansion: CGFloat = 0
    @ObservationIgnored private var dragAccumulatedY: CGFloat = 0

    func beginDrag() {
        dragStartExpansion = expansion
        dragAccumulatedY = 0
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

/// What the sheet's layers read while it moves (set by `PlayerSheetMorph`, interpolated every animation frame).
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

extension EnvironmentValues {
    /// The player sheet's live metrics (only the sheet's fade/offset modifiers read it).
    @Entry var playerSheetMetrics = PlayerSheetMetrics()
}

/// Fades a full-player section in like Android's `DelayedContent` (`normalStartThreshold`), reading the sheet's
/// progress in this small modifier only — the section itself is not re-evaluated while the sheet moves.
struct PlayerSectionFade: ViewModifier {
    let start: CGFloat
    var slide: CGFloat = 0

    @Environment(\.playerSheetMetrics) private var metrics

    func body(content: Content) -> some View {
        let alpha = metrics.sectionAlpha(start: start)
        content
            .opacity(alpha)
            .offset(y: slide * (1 - metrics.progress))
    }
}

extension View {
    func playerSectionFade(start: CGFloat, slide: CGFloat = 0) -> some View {
        modifier(PlayerSectionFade(start: start, slide: slide))
    }
}
