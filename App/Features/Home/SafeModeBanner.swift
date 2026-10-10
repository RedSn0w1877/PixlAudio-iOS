import SwiftUI

/// Home's one-time notice after the app closed unexpectedly while it was working (docs/handoff/2026-10-10-crash-
/// diagnostics.md): heavy jobs are paused until the person reviews them in Active jobs (Retry) or turns safe mode off.
/// A Liquid Glass card tinted with the error container; its dismiss is a plain fill (no glass on glass).
struct SafeModeBanner: View {
    let onReview: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onReview) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.onErrorContainer)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PixlAudio closed unexpectedly while working.")
                            .pixlFont(.bodyLarge, weight: .semibold)
                            .foregroundStyle(theme.onErrorContainer)
                        Text("Heavy jobs are paused — tap to review")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onErrorContainer.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
            .accessibilityLabel("PixlAudio closed unexpectedly while working. Heavy jobs are paused.")
            .accessibilityHint("Opens Active jobs to review them")
            .accessibilityIdentifier("home.safeMode.review")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.onErrorContainer)
                    .frame(width: 32, height: 32)
                    .background(theme.onErrorContainer.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("home.safeMode.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.errorContainer.opacity(GlassTint.container + 0.2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.safeModeBanner")
    }
}
