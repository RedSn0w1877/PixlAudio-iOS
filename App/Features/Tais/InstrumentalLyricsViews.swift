import PixlModel
import SwiftUI

/// Android `InstrumentalRenderAction` (lyrics screen, no lyrics): the waveform icon, "No lyrics for this song yet",
/// the explanation, then one primary button — Render instrumental → Rendering instrumental… (with the job's detail
/// and a bar) → Play instrumental → Play original — and "Find or import lyrics". On the lyrics screen's artwork:
/// a 28 pt clear-glass card; the buttons are fills on it (the primary one `primaryFixedDim`, Android `Button`). The
/// button asks `InstrumentalController.requestSing` like the Sing segment does, so the cloud makes the instrumental
/// when it can (the bar then shows the cloud job's step) and this phone otherwise.
struct InstrumentalRenderAction: View {
    let song: Song
    let onFindLyrics: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.playerTheme) private var theme

    var body: some View {
        let studio = env.tais.studio
        let instrumental = env.tais.instrumental
        let job = studio.state(.instrumental, songId: song.id)
        let inCloud = instrumental.singPhase.isCloud
        let cloudStatus = inCloud ? instrumental.cloudStatus : nil
        let isRunning = job?.isActive == true || inCloud
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
                // Android's indicator in the lyrics sheet takes the song's scheme (the chrome accent here).
                TaisProgressBar(fraction: cloudStatus?.weight ?? Double(job?.percent ?? 0) / 100,
                                colors: (theme.primaryFixedDim, theme.primaryFixedDim.opacity(0.26)))
                Text(inCloud ? cloudStatus?.text ?? "Preparing in the cloud…" : job?.detail ?? "Instrumental queued…")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("lyrics.instrumental.detail")
                Button {
                    // The cloud's job keeps going (its file is kept for next time); only the waiting stops.
                    if inCloud { instrumental.cancelSing() } else { studio.cancel(.instrumental, songId: song.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel").pixlFont(.labelLarge)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .accessibilityIdentifier("lyrics.instrumental.cancel")
            }
            if !isRunning, !ready, case .failed(let reason)? = job?.phase {
                Text(reason).pixlFont(.bodyMedium).foregroundStyle(theme.error)
            }
            Button {
                if instrumental.isActive {
                    instrumental.playOriginal()
                } else {
                    Task { await instrumental.requestSing(for: song) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text(title(isRunning: isRunning, inCloud: inCloud, ready: ready, active: instrumental.isActive))
                        .pixlFont(.labelLarge)
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

    private func title(isRunning: Bool, inCloud: Bool, ready: Bool, active: Bool) -> String {
        if active { return "Play original" }
        if ready { return "Play instrumental" }
        if isRunning { return inCloud ? "Preparing instrumental…" : "Rendering instrumental…" }
        return "Render instrumental"
    }
}
