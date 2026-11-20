import PixlLibrary
import PixlModel
import SwiftUI
import UIKit

/// Song Tap's full-screen surface (Android `SongTapScreen`; `AppCover.songTap`). Milestone 1 is the working route in plain
/// Liquid Glass: Send shows a code for the song that is playing, Receive scans one, and a card says what happened (Add /
/// Not now the first time, then Undo). The beam animation and the Bluetooth tap come in milestone 2 (the animation's
/// timeline is already in PixlCore).
///
/// It is armed only while it is on screen and PixlAudio is in the foreground: leaving the screen or the app disarms, stops
/// the camera and cancels every timer. Reduce Motion needs nothing here yet (nothing moves but the system's own cross-fades).
struct SongTapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var mode: SongTapRole = .send
    @State private var camera: SongTapCamera?
    @State private var cameraStatus = SongTapCameraAccess.current()

    var body: some View {
        let controller = env.songTap
        let ui = controller.ui
        ZStack {
            theme.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 4)
                    if !ui.allowed {
                        turnOnCard(controller)
                    } else {
                        modeSwitch(controller)
                        resultCard(controller, ui)
                        if mode == .send {
                            sendContent(controller, ui)
                        } else {
                            receiveContent(controller)
                        }
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .animation(PixlMotion.state, value: ui.phase)
                .animation(PixlMotion.state, value: ui.code)
            }
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
        }
        .sensoryFeedback(trigger: controller.hapticSerial) { _, _ in
            HapticsPreference.isEnabled ? Self.feedback(for: controller.hapticCue) : nil
        }
        .onAppear {
            controller.nowPlayingChanged(env.playback.current)
            sync(controller)
        }
        .onDisappear {
            controller.disarm()
            stopCamera()
        }
        .onChange(of: scenePhase) { _, _ in sync(controller) }
        .onChange(of: ui.allowed) { _, _ in sync(controller) }
        .onChange(of: mode) { _, new in
            controller.switchRole(new)
            sync(controller)
        }
        .onChange(of: env.playback.current?.id) { _, _ in controller.nowPlayingChanged(env.playback.current) }
        .accessibilityIdentifier("screen.songTap")
    }

    // MARK: Arming and the camera

    /// Armed while the screen is up in the foreground; the camera runs only on the Receive side, once it may.
    private func sync(_ controller: SongTapController) {
        guard controller.allowed, scenePhase == .active else {
            controller.disarm()
            stopCamera()
            return
        }
        controller.arm(mode)
        cameraStatus = SongTapCameraAccess.current()
        if mode == .receive, cameraStatus == .allowed {
            startCamera(controller)
        } else {
            stopCamera()
        }
    }

    private func startCamera(_ controller: SongTapController) {
        let active = camera ?? SongTapCamera { text in
            Task { @MainActor in controller.scanned(text) }
        }
        camera = active
        active.start()
    }

    private func stopCamera() {
        camera?.stop()
    }

    private static func feedback(for cue: SongTapHapticCue) -> SensoryFeedback {
        switch cue {
        case .tick: .selection
        case .confirm: .impact(weight: .light)
        case .success: .success
        case .warn: .warning
        }
    }

    // MARK: Bars

    private var topBar: some View {
        ZStack {
            Text(SongTapStrings.title)
                .pixlFont(.custom(size: 28, weight: .heavy))
                .foregroundStyle(theme.onSurface)
            HStack {
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: "Close", size: 40, iconSize: 17,
                                  tint: theme.surfaceContainerLow.opacity(GlassTint.surface)) { dismiss() }
                    .padding(.leading, 10)
                Spacer()
            }
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(theme.surface.ignoresSafeArea(edges: .top))
    }

    // MARK: Turn on

    private func turnOnCard(_ controller: SongTapController) -> some View {
        GlassCard(cornerRadius: 28, tint: theme.surfaceContainerHigh) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .accessibilityHidden(true)
                Text(SongTapStrings.offHeadline)
                    .pixlFont(.headlineSmall)
                    .foregroundStyle(theme.onSurface)
                Text(SongTapStrings.offBody)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                prominentButton(SongTapStrings.turnOn, id: "songTap.turnOn") { controller.setAllowed(true) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Modes

    private func modeSwitch(_ controller: SongTapController) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                modePill(SongTapStrings.modeSend, role: .send, id: "songTap.mode.send")
                modePill(SongTapStrings.modeReceive, role: .receive, id: "songTap.mode.receive")
            }
        }
    }

    private func modePill(_ title: String, role: SongTapRole, id: String) -> some View {
        let selected = mode == role
        return Button {
            guard mode != role else { return }
            mode = role
        } label: {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(selected ? theme.onPrimary : theme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: selected ? theme.primary.opacity(GlassTint.prominent) : nil, interactive: true)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: Send

    @ViewBuilder
    private func sendContent(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        if let playing = ui.nowPlaying {
            VStack(alignment: .leading, spacing: 12) {
                Text(SongTapStrings.sendNowPlaying)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.primary)
                songRow(title: playing.title, artist: playing.artist, artUrl: playing.artUrl)
                if let code = ui.code {
                    SongTapQrView(text: code, accessibilityText: SongTapStrings.codeDescription)
                    Text(SongTapStrings.codeHint)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                    plainButton(SongTapStrings.hideCode, id: "songTap.hideCode") { controller.hideCode() }
                } else if !playing.canSend {
                    Text(SongTapStrings.sendCant)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                } else {
                    prominentButton(SongTapStrings.showCode, id: "songTap.showCode") { controller.showCode() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(SongTapStrings.sendNothing)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Receive

    @ViewBuilder
    private func receiveContent(_ controller: SongTapController) -> some View {
        switch cameraStatus {
        case .allowed:
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(theme.surfaceContainerHighest)
                    if let camera {
                        SongTapCameraPreview(camera: camera)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
                Text(SongTapStrings.scanHint)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notAsked:
            VStack(alignment: .leading, spacing: 12) {
                Text(SongTapStrings.cameraNeeded)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                // The camera is asked for here, the first time the listener chooses to scan, and nowhere else.
                prominentButton(SongTapStrings.allowCamera, id: "songTap.allowCamera") {
                    Task {
                        _ = await SongTapCameraAccess.request()
                        sync(controller)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .blocked:
            VStack(alignment: .leading, spacing: 12) {
                Text(SongTapStrings.cameraBlocked)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                prominentButton(SongTapStrings.openSettings, id: "songTap.openSettings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The card

    /// What happened, in one card: the question the first time, the song that was added, or why not.
    @ViewBuilder
    private func resultCard(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        let phase = ui.phase
        let receiving = ui.role == .receive
        let showsSong = ui.card != nil && receiving && (phase == .offered || phase == .transferring || phase == .saved)
        let showsText = phase == .failed || phase == .declined || phase == .cancelled || (ui.notice == .invalidCode && phase == .armed)
        if showsSong || showsText {
            GlassCard(cornerRadius: 28, tint: theme.secondaryContainer) {
                VStack(alignment: .leading, spacing: 12) {
                    if showsSong, let card = ui.card {
                        songRow(title: card.title, artist: card.artist, artUrl: card.artUrl)
                        songCardFooter(controller, ui, phase: phase)
                    } else {
                        HStack {
                            Text(noticeText(ui))
                                .pixlFont(.titleMedium)
                                .foregroundStyle(theme.onSecondaryContainer)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            textButton(SongTapStrings.cardOk, id: "songTap.ok") { controller.dismiss() }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.opacity)
            .accessibilityIdentifier("songTap.card")
        }
    }

    @ViewBuilder
    private func songCardFooter(_ controller: SongTapController, _ ui: SongTapUiState, phase: SongTapPhase) -> some View {
        switch phase {
        case .offered:
            Text(SongTapStrings.cardAsk)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSecondaryContainer)
            HStack(spacing: 8) {
                prominentButton(SongTapStrings.cardAdd, id: "songTap.add") { controller.accept() }
                plainButton(SongTapStrings.cardNotNow, id: "songTap.notNow") { controller.decline() }
            }
        case .transferring:
            Text(SongTapStrings.cardAdding)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSecondaryContainer)
        default:
            HStack {
                Text(ui.session.alreadyHad ? SongTapStrings.cardAlready : SongTapStrings.cardSaved)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !ui.session.alreadyHad {
                    textButton(SongTapStrings.cardUndo, id: "songTap.undo") { controller.undo() }
                }
            }
        }
    }

    private func noticeText(_ ui: SongTapUiState) -> String {
        if let notice = ui.notice { return SongTapStrings.notice(notice) }
        switch ui.phase {
        case .declined: return SongTapStrings.declined
        case .cancelled: return SongTapStrings.cancelled
        default: return SongTapStrings.notice(.saveFailed)
        }
    }

    // MARK: Pieces

    private func songRow(title: String, artist: String, artUrl: String?) -> some View {
        HStack(spacing: 12) {
            ArtworkView(source: ArtworkSource(uriString: artUrl), size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(artist)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func prominentButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.titleMedium, weight: .semibold)
                .foregroundStyle(theme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
        .accessibilityIdentifier(id)
    }

    private func plainButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.titleMedium, weight: .semibold)
                .foregroundStyle(theme.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: nil, interactive: true)
        .accessibilityIdentifier(id)
    }

    private func textButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.titleMedium, weight: .semibold)
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .accessibilityIdentifier(id)
    }
}
