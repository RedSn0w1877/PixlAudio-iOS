import PixlModel
import SwiftUI
import UIKit

// Gestures (iOS-first, owner request 2026-10-18). Every horizontal gesture here decides once, at the first movement
// past a small slop, whether the drag is clearly sideways (`GesturePolicy.intent`); only then does it follow the finger
// or act. A vertical or diagonal drag is never touched, so lists keep scrolling and the player sheet keeps its drag.
// They are a UIKit pan recognizer that refuses to begin unless the finger is moving mostly sideways. A SwiftUI
// `DragGesture` (even via `simultaneousGesture`) claims a drag in ANY direction after its minimum distance and cancels
// the scroll view's pan, so lists whose rows carry it stopped scrolling when the touch began on a row.

/// A horizontal swipe on a view: reports the sideways movement while the drag is clearly horizontal, and the committed
/// direction (or nil: not far or fast enough) when it ends.
struct HorizontalSwipeModifier: ViewModifier {
    var isEnabled: Bool
    var onChange: (CGFloat) -> Void = { _ in }
    let onEnd: (SwipeDirection?) -> Void

    func body(content: Content) -> some View {
        content.gesture(HorizontalPanRecognizer(isEnabled: isEnabled, onChange: onChange, onEnd: onEnd))
    }
}

/// The UIKit pan behind `horizontalSwipe`. `gestureRecognizerShouldBegin` only says yes when the finger is moving
/// clearly sideways, so a vertical or diagonal drag never reaches this recognizer and the scroll view (or the player
/// sheet's drag) gets it untouched.
struct HorizontalPanRecognizer: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (SwipeDirection?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChange(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            onChange(0)
            onEnd(GesturePolicy.swipe(dx: translation, velocityX: velocity))
        case .cancelled, .failed:
            onChange(0)
            onEnd(nil)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }
    }
}

extension View {
    /// A clearly horizontal swipe. `onChange` gets the movement while it lasts (0 at the end).
    func horizontalSwipe(isEnabled: Bool = true, onChange: @escaping (CGFloat) -> Void = { _ in },
                         onEnd: @escaping (SwipeDirection?) -> Void) -> some View {
        modifier(HorizontalSwipeModifier(isEnabled: isEnabled, onChange: onChange, onEnd: onEnd))
    }
}

// MARK: - Swipe a song row to queue it

/// Swipe a song row right to "Play next", left to "Add to queue" (Settings › Behavior › Gestures › Lists). The row
/// follows the finger on a rubber band, the action shows behind it, a release past the commit distance does it with a
/// haptic and a toast. Off for VoiceOver (the same actions are in the row's actions menu) and while the page edits
/// its list. Not used by the queue itself (its rows keep their own gestures).
struct SwipeToQueueModifier: ViewModifier {
    let song: Song
    var isEnabled: Bool

    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.appTheme) private var theme
    @State private var dragX: CGFloat = 0
    @State private var committed = 0

    private static let limit: CGFloat = 84

    func body(content: Content) -> some View {
        let active = isEnabled && settings.behavior.gestureListSwipeQueue && !voiceOver
        ZStack {
            if dragX != 0 { reveal }
            content
                .offset(x: dragX)
        }
        .horizontalSwipe(isEnabled: active, onChange: { dx in
            dragX = GesturePolicy.rubberBand(Double(dx), limit: Double(Self.limit)).cgFloat
        }, onEnd: { direction in
            withAnimation(PixlMotion.state) { dragX = 0 }
            guard let direction else { return }
            committed += 1
            switch direction {
            case .right:
                playback.playNext([song])
                LibraryToast.shared.show("Playing next")
            case .left:
                playback.addToQueue([song])
                LibraryToast.shared.show("Added to queue")
            }
        })
        .pixlHaptic(.impact(weight: .medium), trigger: committed)
        .accessibilityActions {
            Button("Play next") {
                playback.playNext([song])
                LibraryToast.shared.show("Playing next")
            }
            Button("Add to queue") {
                playback.addToQueue([song])
                LibraryToast.shared.show("Added to queue")
            }
        }
    }

    /// The action under the row: "Play next" on the left (a right swipe), "Add to queue" on the right.
    private var reveal: some View {
        let progress = min(abs(dragX) / 56, 1)
        let isNext = dragX > 0
        return HStack {
            if !isNext { Spacer(minLength: 0) }
            Label(isNext ? "Play next" : "Add to queue",
                  systemImage: isNext ? "text.line.first.and.arrowtriangle.forward" : "text.line.last.and.arrowtriangle.forward")
                .labelStyle(.titleAndIcon)
                .pixlFont(.labelMedium, weight: .semibold)
                .foregroundStyle(isNext ? theme.onTertiary : theme.onSecondaryContainer)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(isNext ? theme.tertiary : theme.secondaryContainer))
                .scaleEffect(0.85 + 0.15 * progress)
                .opacity(progress)
            if isNext { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Swipe-to-queue on a song row (see `SwipeToQueueModifier`).
    func swipeToQueue(song: Song, isEnabled: Bool = true) -> some View {
        modifier(SwipeToQueueModifier(song: song, isEnabled: isEnabled))
    }
}

private extension Double {
    var cgFloat: CGFloat { CGFloat(self) }
}
