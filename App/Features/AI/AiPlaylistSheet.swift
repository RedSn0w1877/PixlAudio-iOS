import SwiftUI

/// The AI playlist sheet (Android `AiPlaylistSheet`, opened by Daily Mix's sparkle button): the animated AI badge
/// with "Daily Mix / AI Playlist Generator" (→ "Perfectly Curated / Your sonic journey is ready"), the description,
/// the playlist-size card (min / max songs), the prompt field, the error card (tap to retry), the success card and
/// the morphing Generate button. Same layout and sizes as the Compose sheet; Material surfaces are tinted glass and
/// the text fields inside the size card are plain fills (no glass on glass).
struct AiPlaylistSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    @State private var prompt = ""
    @State private var minLength = "5"
    @State private var maxLength = "15"
    @FocusState private var focusedField: Field?

    private enum Field { case min, max, prompt }

    private var controller: AIPlaylistController { env.ai.playlist }

    var body: some View {
        let isGenerating = controller.isGenerating
        let isSuccess = controller.isSuccess
        ScrollView {
            VStack(spacing: 16) {
                header(isGenerating: isGenerating, isSuccess: isSuccess)
                Text("Describe the vibe, mood, or activity and let AI curate the perfect playlist from your library.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sizeCard
                promptField
                if let error = controller.error {
                    errorCard(error)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if isSuccess {
                    successCard
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Spacer().frame(height: 8)
                generateButton(isGenerating: isGenerating, isSuccess: isSuccess)
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .padding(.top, 16)
            .contentShape(.rect)
            .onTapGesture { focusedField = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(PixlMotion.state, value: controller.error)
        .animation(PixlMotion.state, value: isSuccess)
        .onDisappear { controller.reset() }
        .accessibilityIdentifier("screen.aiPlaylist")
    }

    // MARK: Header

    private func header(isGenerating: Bool, isSuccess: Bool) -> some View {
        HStack(spacing: 16) {
            AIBadge(isGenerating: isGenerating, size: 64, iconSize: 28,
                    tint: isGenerating ? theme.primaryContainer : theme.tertiaryContainer,
                    foreground: isGenerating ? theme.onPrimaryContainer : theme.onTertiaryContainer)
            VStack(alignment: .leading, spacing: 0) {
                Text(isSuccess ? "Perfectly Curated" : "Daily Mix")
                    .pixlFont(.custom(size: 32, weight: .bold, lineHeight: 40))
                    .foregroundStyle(isSuccess ? theme.tertiary : theme.primary)
                Text(isSuccess ? "Your sonic journey is ready" : "AI Playlist Generator")
                    .pixlFont(.titleMedium)
                    .foregroundStyle(isSuccess ? theme.tertiary : theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 8)
    }

    // MARK: Size card

    private var sizeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlist size")
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.onSurface)
            HStack(spacing: 12) {
                AIFilledField(label: "Min songs", text: digitsBinding($minLength), cornerRadius: 16, keyboard: .numberPad)
                    .focused($focusedField, equals: .min)
                AIFilledField(label: "Max songs", text: digitsBinding($maxLength), cornerRadius: 16, keyboard: .numberPad)
                    .focused($focusedField, equals: .max)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
    }

    private func digitsBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0.filter(\.isNumber) })
    }

    // MARK: Prompt

    private var promptField: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return TextField("", text: $prompt, prompt: Text("e.g. Chill evening vibes, upbeat workout energy…")
                            .foregroundStyle(theme.onSurfaceVariant.opacity(0.6)),
                         axis: .vertical)
            .lineLimit(2...4)
            .pixlFont(.bodyLarge)
            .foregroundStyle(theme.onSurface)
            .tint(theme.primary)
            .focused($focusedField, equals: .prompt)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixlGlass(in: shape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
            .overlay(alignment: .bottom) {
                // Material's error indicator line (the field keeps a transparent indicator otherwise).
                if controller.error != nil {
                    Rectangle().fill(theme.error).frame(height: 2)
                }
            }
            .clipShape(shape)
            .accessibilityIdentifier("aiPlaylist.prompt")
    }

    // MARK: Cards

    private func errorCard(_ error: String) -> some View {
        Button { controller.retry() } label: {
            VStack(spacing: 8) {
                Text(error)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onErrorContainer)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.error)
                    Text("Tap to Retry")
                        .pixlFont(.labelLarge, weight: .bold)
                        .foregroundStyle(theme.error)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.errorContainer.opacity(GlassTint.container), interactive: true)
        .accessibilityIdentifier("aiPlaylist.error")
    }

    private var successCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.onTertiaryContainer)
            Text(controller.status ?? "Sonic journey synthesized!")
                .pixlFont(.bodyLarge, weight: .heavy)
                .foregroundStyle(theme.onTertiaryContainer)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.tertiaryContainer.opacity(GlassTint.container))
    }

    // MARK: Generate button

    /// 56 pt tall, 24 pt side insets; a capsule that squares to 24 pt corners while pressed or generating and dips to
    /// 0.92 (Android `DampingRatioMediumBouncy` spring); `primaryContainer` once there is a prompt. Fires on release.
    private func generateButton(isGenerating: Bool, isSuccess: Bool) -> some View {
        let isBlank = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canGenerate = !isBlank && !isGenerating && !isSuccess
        let foreground: Color
        if isSuccess {
            foreground = theme.onTertiaryContainer
        } else if isGenerating || !isBlank {
            foreground = theme.onPrimaryContainer
        } else {
            foreground = theme.onSurfaceVariant
        }
        return Button {
            guard canGenerate else { return }
            focusedField = nil
            controller.generate(prompt: prompt, minLength: Int(minLength) ?? 5, maxLength: Int(maxLength) ?? 15)
        } label: {
            HStack(spacing: 12) {
                if isSuccess {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
                    Text("Ready to Play").pixlFont(.titleMedium, weight: .semibold)
                } else if isGenerating {
                    ProgressView().controlSize(.regular).tint(foreground)
                    Text(controller.status ?? "Generating…").pixlFont(.titleMedium, weight: .semibold).lineLimit(1)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold))
                    Text("Generate Playlist").pixlFont(.titleMedium, weight: .semibold)
                }
            }
            .foregroundStyle(foreground)
        }
        .buttonStyle(AIMorphButtonStyle(isBusy: isGenerating, pressable: canGenerate,
                                        tint: !isBlank || isGenerating ? theme.primaryContainer.opacity(GlassTint.prominent)
                                                                       : theme.surfaceContainerHighest.opacity(GlassTint.surface)))
        .padding(.horizontal, 24)
        .accessibilityIdentifier("aiPlaylist.generate")
    }
}

/// Android's bouncy generate button: 56 pt glass whose corners go from capsule to 24 pt while pressed or busy and
/// which dips to 0.92 while pressed (spring, damping 0.5).
struct AIMorphButtonStyle: ButtonStyle {
    let isBusy: Bool
    let pressable: Bool
    let tint: Color
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && pressable
        let radius: CGFloat = pressed || isBusy ? 24 : height / 2
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(.rect(cornerRadius: radius))
            .pixlGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, interactive: pressable)
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: pressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: isBusy)
    }
}

/// The AI badge (Android: a 64 dp `Surface` with one 10 dp corner and the rest 52 dp, `AutoAwesome` inside): tinted
/// glass that spins (3 s, fast-out-slow-in) and breathes (1 → 1.15, 800 ms) while generating.
struct AIBadge: View {
    let isGenerating: Bool
    var size: CGFloat = 64
    var iconSize: CGFloat = 28
    let tint: Color
    let foreground: Color

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: size * 10 / 64, bottomLeadingRadius: size / 2,
                                           bottomTrailingRadius: size / 2, topTrailingRadius: size / 2, style: .continuous)
        Image(systemName: "sparkles")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .pixlGlass(in: shape, tint: tint.opacity(GlassTint.container))
            .keyframeAnimator(initialValue: BadgeMotion(), repeating: isGenerating) { content, motion in
                content
                    .rotationEffect(.degrees(isGenerating ? motion.angle : 0))
                    .scaleEffect(isGenerating ? motion.scale : 1)
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    CubicKeyframe(360, duration: 3)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.15, duration: 0.8)
                    CubicKeyframe(1, duration: 0.8)
                    CubicKeyframe(1.15, duration: 0.7)
                    CubicKeyframe(1, duration: 0.7)
                }
            }
            .accessibilityHidden(true)
    }
}

nonisolated struct BadgeMotion: Sendable {
    var angle: Double = 0
    var scale: Double = 1
}

/// A filled text field with a floating label (Android `OutlinedTextField` on a `surfaceContainerHigh` fill with no
/// indicator): a plain fill, used where the field sits on a glass card.
struct AIFilledField: View {
    let label: String
    @Binding var text: String
    var cornerRadius: CGFloat = 16
    var keyboard: UIKeyboardType = .default
    var placeholder: String?
    var enabled = true

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
            TextField("", text: $text, prompt: placeholder.map { Text($0).foregroundStyle(theme.onSurfaceVariant.opacity(0.6)) })
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .keyboardType(keyboard)
                .tint(theme.primary)
                .disabled(!enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainerHigh.opacity(0.7), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(enabled ? 1 : 0.6)
    }
}
