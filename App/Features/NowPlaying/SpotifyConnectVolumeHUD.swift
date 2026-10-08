import Observation
import SwiftUI

/// PixlAudio's own volume pop-up for the Spotify Connect device (owner request 2026-10-07: the phone's volume buttons
/// drive the device; the system pop-up is kept away, `SpotifyConnectVolumeButtons`). Shown by the presses only — the
/// sliders move by themselves — and hidden 1.5 s after the last one. Nothing ticks while it is hidden.
@Observable
final class SpotifyConnectVolumeHUDModel {
    private(set) var isVisible = false
    private(set) var percent = 0
    private(set) var deviceName = ""
    /// The devices sheet is open: its hero slider already moves, so the pop-up stays away.
    var isSuppressed = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    static let visibleFor: Duration = .milliseconds(1500)

    /// Shows (or updates) the pop-up. `pinned` keeps it up (UI tests take its screenshot).
    func show(percent: Int, deviceName: String, pinned: Bool = false) {
        hideTask?.cancel()
        if self.percent != percent { self.percent = percent }
        if self.deviceName != deviceName { self.deviceName = deviceName }
        if !isVisible { withAnimation(PixlMotion.bars) { isVisible = true } }
        guard !pinned else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled, let self else { return }
            withAnimation(PixlMotion.bars) { self.isVisible = false }
            // VoiceOver hears where the burst ended, once (never focused, it disappears on its own).
            PixlAccessibility.announce("\(self.deviceName) volume \(self.percent)%")
        }
    }

    /// The session ended.
    func hide() {
        hideTask?.cancel()
        hideTask = nil
        if isVisible { withAnimation(PixlMotion.bars) { isVisible = false } }
    }
}

/// The pop-up: a top-centre glass capsule with the device's level icon, its name, a thin level track and the
/// percentage. One glass layer; the track is a plain fill on it.
struct SpotifyConnectVolumeHUD: View {
    let percent: Int
    let deviceName: String

    @Environment(\.appTheme) private var theme

    /// Wide enough for a typical speaker name ("Kitchen Echo Show") on one line, while the whole capsule (264 pt) still
    /// fits between the full player's collapse and queue buttons.
    private static let trackWidth: CGFloat = 144

    var body: some View {
        let spoken = "Volume for \(deviceName), \(percent)%"
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(deviceName)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.onSurface.opacity(0.14))
                    Capsule().fill(theme.primary)
                        .frame(width: Self.trackWidth * CGFloat(min(max(percent, 0), 100)) / 100)
                }
                .frame(width: Self.trackWidth, height: 4)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: percent)
            }
            .frame(width: Self.trackWidth, alignment: .leading)
            Text("\(percent)%")
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing) // fits "100%": the capsule never changes width
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        // As strong as Connect's toasts, not a panel's tint: the pop-up floats over whatever is at the top (the full
        // player's output pill, the lyrics header), and lighter tints let that content's text show through it.
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.prominent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("spotifyConnect.volumeHUD")
    }

    private var symbolName: String {
        switch percent {
        case ...0: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// Places the pop-up at the top centre of the content. Only this modifier reads the model, so a press redraws the
/// pop-up and nothing under it. `followsPresentations`: the shell's copy steps aside while a sheet or a cover is up
/// (each presentation shows its own copy, `SheetDestination` / `CoverDestination`).
private struct SpotifyConnectVolumeHUDOverlay: ViewModifier {
    var followsPresentations = false

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            let hud = env.spotifyConnect.volumeHUD
            if hud.isVisible, !hud.isSuppressed, !(followsPresentations && isCovered) {
                SpotifyConnectVolumeHUD(percent: hud.percent, deviceName: hud.deviceName)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    /// A sheet or a full-screen cover (not the full player, which lives in the shell) is up.
    private var isCovered: Bool {
        router.sheet != nil || (router.cover != nil && router.cover != .nowPlaying)
    }
}

extension View {
    /// Spotify Connect's volume pop-up over this content. The shell passes `followsPresentations: true`.
    func spotifyConnectVolumeHUD(followsPresentations: Bool = false) -> some View {
        modifier(SpotifyConnectVolumeHUDOverlay(followsPresentations: followsPresentations))
    }
}
