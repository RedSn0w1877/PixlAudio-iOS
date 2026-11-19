import PixlLibrary
import SwiftUI

/// The bar that follows a piece of feedback (docs/brain-spec.md, 8.5; Android `BrainNoticeBar`): what happened,
/// Undo, and after "Not for me" the step to "Less from the artist". One inverse-surface glass shape, as the queue's
/// own undo bar; its buttons are plain text on it (no glass on glass). `BrainActions` reads it out for VoiceOver.
struct BrainNoticeBar: View {
    let notice: BrainNotice
    let onUndo: () -> Void
    let onLessFrom: () -> Void
    var onMute: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(BrainStrings.notice(notice))
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.inverseOnSurface)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
                .padding(.bottom, notice.canUndo || notice.canLessFrom || notice.canMute ? 4 : 12)
            if notice.canUndo || notice.canLessFrom || notice.canMute {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if notice.canLessFrom {
                        action(BrainStrings.lessFrom(notice.artistName), identifier: "brain.notice.lessFrom", onLessFrom)
                    }
                    if notice.canMute {
                        action(BrainStrings.muteArtist(notice.artistName), identifier: "brain.notice.mute", onMute)
                    }
                    if notice.canUndo {
                        action(BrainStrings.undo, identifier: "brain.notice.undo", onUndo)
                    }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.inverseSurface.opacity(GlassTint.prominent))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brain.notice")
    }

    private func action(_ title: String, identifier: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .pixlFont(.labelLarge, weight: .bold)
                .foregroundStyle(theme.inversePrimary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier(identifier)
    }
}

/// Shows the bar of `BrainActions` over the content, above the bars at the bottom.
struct BrainNoticeOverlay: ViewModifier {
    var bottomPadding: CGFloat

    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        let actions = env.brainActions
        content.overlay(alignment: .bottom) {
            if let notice = actions.notice {
                BrainNoticeBar(notice: notice, onUndo: { actions.undo() }, onLessFrom: { actions.lessFromNoticeArtist() },
                               onMute: { actions.muteNoticeArtist() })
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PixlMotion.bars, value: actions.notice?.serial)
    }
}

extension View {
    /// The music brain's feedback bar ("Got it. ..." with Undo), on the shell and on the sheets feedback is given from.
    func brainNoticeBar(bottomPadding: CGFloat) -> some View { modifier(BrainNoticeOverlay(bottomPadding: bottomPadding)) }
}
