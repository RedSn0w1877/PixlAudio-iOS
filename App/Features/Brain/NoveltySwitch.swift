import PixlLibrary
import SwiftUI

/// Familiar / Blend / Discover (docs/brain-spec.md, 8.3; Android `NoveltySwitch`): how much of what the engine picks
/// is new music. Three stops under the queue's Autoplay or Station line: the chosen one is a `primary` glass
/// capsule, the others a hint of `surfaceContainerHighest`, the queue toolbar's recipe.
///
/// The three capsules share one container (they render together, spaced wider than it blends). Not interactive
/// glass: inside the queue's scroll view that would take the pans that begin on it; the press scales instead.
struct NoveltySwitch: View {
    /// `Novelty.familiar`, `.blend` or `.discover`.
    let level: Int
    let onChange: (Int) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 6) {
                stop(Novelty.familiar, identifier: "queue.novelty.familiar")
                stop(Novelty.blend, identifier: "queue.novelty.blend")
                stop(Novelty.discover, identifier: "queue.novelty.discover")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrainStrings.noveltyDescription)
        .pixlHaptic(.selection, trigger: level)
    }

    private func stop(_ value: Int, identifier: String) -> some View {
        let selected = value == level
        return Button {
            if !selected { onChange(value) }
        } label: {
            Text(BrainStrings.novelty(value))
                .pixlFont(.labelLarge, weight: selected ? .semibold : .medium)
                .foregroundStyle(selected ? theme.onPrimary : theme.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
        .pixlGlass(in: Capsule(),
                   tint: selected ? theme.primary.opacity(GlassTint.prominent)
                                  : theme.surfaceContainerHighest.opacity(GlassTint.surface))
        .animation(PixlMotion.selection, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
