import PixlModel
import SwiftUI

/// Android `InstrumentalRenderAction` (lyrics screen, no lyrics): the waveform icon, "No lyrics for this song yet",
/// the explanation, then one primary button — Render instrumental → Rendering instrumental… (with the job's detail
/// and a bar) → Play instrumental → Play original — and "Find or import lyrics". On the lyrics screen's artwork:
/// a 28 pt clear-glass card; the buttons are fills on it (the primary one `primaryFixedDim`, Android `Button`).
struct InstrumentalRenderAction: View {
    let song: Song
    let onFindLyrics: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.playerTheme) private var theme

    var body: some View {
        let studio = env.tais.studio
        let instrumental = env.tais.instrumental
        let job = studio.state(.instrumental, songId: song.id)
        let isRunning = job?.isActive == true
        let ready = instrumental.isAvailable
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.primaryFixedDim)
                .accessibilityHidden(true)
            Text("No lyrics for this song yet")
                .pixlFont(.headlineSmall)
                .foregroundStyle(.white)
            Text("You can still listen without vocals. Render an instrumental once and keep it on this device for offline listening.")
                .pixlFont(.bodyLarge)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            if isRunning {
                TaisProgressBar(fraction: Double(job?.percent ?? 0) / 100)
                Text(job?.detail ?? "Instrumental queued…")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("lyrics.instrumental.detail")
            }
            if !isRunning, !ready, case .failed(let reason)? = job?.phase {
                Text(reason).pixlFont(.bodyMedium).foregroundStyle(theme.error)
            }
            Button {
                if instrumental.isActive {
                    instrumental.playOriginal()
                } else if ready {
                    instrumental.playInstrumental()
                } else {
                    studio.start(.instrumental, song: song)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text(title(isRunning: isRunning, ready: ready, active: instrumental.isActive)).pixlFont(.labelLarge)
                }
                .foregroundStyle(theme.onPrimaryFixed)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(theme.primaryFixedDim, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
            .disabled(isRunning || instrumental.isSwitching)
            .opacity(isRunning ? 0.5 : 1)
            .accessibilityIdentifier("lyrics.instrumental")
            Button(action: onFindLyrics) {
                Text("Find or import lyrics")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.primaryFixedDim)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
            .accessibilityIdentifier("lyrics.findLyrics")
        }
        .padding(24)
        .glassEffect(Glass.clear.tint(Color.black.opacity(0.22)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(PixlMotion.state, value: isRunning)
        .animation(PixlMotion.state, value: ready)
    }

    private func title(isRunning: Bool, ready: Bool, active: Bool) -> String {
        if active { return "Play original" }
        if ready { return "Play instrumental" }
        if isRunning { return "Rendering instrumental…" }
        return "Render instrumental"
    }
}

/// Android `FloatingInstrumentalToggle` (above the lyrics controls, trailing; only when the song has a render): a
/// 44 pt pill that grows from a circle to 172 pt with "Instrumental" while the instrumental plays. Clear glass over
/// the artwork tinted with the chrome container; the accent marks the active state.
struct InstrumentalLyricsToggle: View {
    let chrome: LyricsChromeColors
    let brightArt: Bool

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let instrumental = env.tais.instrumental
        if instrumental.isAvailable {
            let active = instrumental.isActive
            HStack {
                Spacer(minLength: 0)
                Button { instrumental.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(active ? chrome.accent : chrome.content)
                        if active {
                            Text("Instrumental")
                                .pixlFont(.labelLarge)
                                .foregroundStyle(chrome.accent)
                                .lineLimit(1)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: active ? 172 : 44, height: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(chrome.panelGlass(brightArt: brightArt, interactive: true), in: Capsule())
                .disabled(instrumental.isSwitching)
                .accessibilityLabel(active ? "Play original version" : "Play instrumental version")
                .accessibilityIdentifier("lyrics.instrumentalToggle")
            }
            .padding(.bottom, 8)
            .animation(.spring(response: 0.45, dampingFraction: 0.62), value: active)
        }
    }
}
