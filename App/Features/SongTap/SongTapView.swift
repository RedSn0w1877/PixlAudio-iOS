import PixlLibrary
import PixlModel
import SwiftUI
import UIKit

/// Song Tap's full-screen surface (Android `SongTapScreen`; `AppCover.songTap`).
///
/// Send: the song that is playing, large; touch the backs of the two phones together and it flies off the top of this screen into
/// the other phone. Receive: wait, and a Liquid Glass card with the song enters from the top. A glow at the top edge grows as the
/// other phone comes close. A code (shown or scanned) does the same job without Bluetooth and is one tap away on both sides.
///
/// It is armed only while it is on screen and PixlAudio is in the foreground: leaving the screen or the app disarms, stops the
/// camera, the radio and the sensor, and cancels every timer. The beam is drawn by `SongTapBeam.swift` from the pure timeline in
/// PixlCore; with Reduce Motion it is a 150 ms cross-fade and the haptics stay.
struct SongTapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var mode: SongTapRole = .send
    @State private var useCode = false
    @State private var scanning = false
    @State private var camera: SongTapCamera?
    @State private var cameraStatus = SongTapCameraAccess.current()
    @State private var rootHeight: CGFloat = 0
    @State private var pulseAt: Date?
    /// A phone the listener picked from the nearby list, waiting for its "Song drop to X?" answer.
    @State private var picked: SongTapNearbyEntry?
    /// The phone that was just answered Yes: the question is not asked again while the offer is being made.
    @State private var answered: Int?

    /// What a beam needs to run: when it changes, the haptic cues start over on the new clock.
    private struct BeamKey: Hashable {
        var role: SongTapRole
        var startMs: Int64
        var reduced: Bool
    }

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
                        bluetoothCard(ui)
                        resultCard(controller, ui)
                        if mode == .send {
                            sendContent(controller, ui)
                        } else {
                            receiveContent(controller, ui)
                        }
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .animation(PixlMotion.state, value: ui.phase)
                .animation(PixlMotion.state, value: ui.code)
            }
            // The artwork flies out through the top of the screen: the list must not clip it.
            .scrollClipDisabled()
            .safeAreaInset(edge: .top, spacing: 0) { topBar }

            SongTapGlowLayer(model: controller.glow, beamRole: ui.beamRole, beamStartMs: ui.beamStartMs, reduced: ui.beamReduced,
                             pulseAt: pulseAt)

            if ui.beamRole == .receive, let card = ui.card {
                SongTapReceiveBeamCard(card: card, phase: ui.phase, alreadyHad: ui.session.alreadyHad, from: ui.peerName,
                                       beamStartMs: ui.beamStartMs, reduced: ui.beamReduced, rootHeight: rootHeight,
                                       onUndo: { controller.undo() })
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rootHeight = $0 }
        .sensoryFeedback(trigger: controller.hapticSerial) { _, _ in
            HapticsPreference.isEnabled ? Self.feedback(for: controller.hapticCue) : nil
        }
        // The beam's own vibrations, on its clock; a new beam (or none) cancels the old run.
        .task(id: ui.beamRole.map { BeamKey(role: $0, startMs: ui.beamStartMs, reduced: ui.beamReduced) }) {
            if let role = ui.beamRole { await controller.playBeamCues(role: role, startMs: ui.beamStartMs, reduced: ui.beamReduced) }
        }
        // The moment of contact: the glow flares once.
        .onChange(of: ui.phase) { _, phase in
            // Reduce Motion is read now, not from the last beam: the flag on the state is only set when a beam starts.
            if (phase == .offered || phase == .transferring), ui.session.peer != 0, !controller.reducedMotion() { pulseAt = Date() }
        }
        .task(id: pulseAt) {
            guard pulseAt != nil else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { pulseAt = nil }
        }
        .onAppear {
            controller.nowPlayingChanged(env.playback.current)
            sync(controller)
        }
        .onDisappear {
            controller.disarm()
            controller.endSongDrop()
            stopCamera()
        }
        // "Song drop to X?": for a phone the listener picked from the list, or for one that came inside the strict near gate.
        .alert(dropTitle(asking(ui)), isPresented: Binding(get: { asking(ui) != nil }, set: { if !$0 { picked = nil } }),
               presenting: asking(ui)) { entry in
            Button(SongTapStrings.dropYes) {
                answered = entry.id
                picked = nil
                controller.approve(peer: entry.id, name: entry.name)
            }
            Button(SongTapStrings.dropNo, role: .cancel) {
                answered = entry.id
                picked = nil
                controller.decideNo(peer: entry.id)
            }
        } message: { _ in
            Text(SongTapStrings.dropConfirmBody(ui.nowPlaying?.title ?? ""))
        }
        .onChange(of: ui.prompt?.id) { _, new in if new != answered { answered = nil } }
        .onChange(of: scenePhase) { _, _ in sync(controller) }
        .onChange(of: ui.allowed) { _, _ in sync(controller) }
        .onChange(of: mode) { _, new in
            useCode = false
            scanning = false
            controller.switchRole(new)
            sync(controller)
        }
        .onChange(of: scanning) { _, _ in sync(controller) }
        .onChange(of: env.playback.current?.id) { _, _ in controller.nowPlayingChanged(env.playback.current) }
        .accessibilityIdentifier("screen.songTap")
    }

    // MARK: Song Drop: the question

    private func dropTitle(_ entry: SongTapNearbyEntry?) -> String { SongTapStrings.dropConfirmTitle(entry?.name ?? "") }

    /// The phone to ask "Song drop to X?" about: the one picked from the list, else the one the route says is inside the near gate. Only
    /// while sending Bluetooth, waiting, with a song that can be sent and no code on screen.
    private func asking(_ ui: SongTapUiState) -> SongTapNearbyEntry? {
        let waiting = ui.phase == .armed || ui.phase == .found || ui.phase == .near
        guard ui.allowed, mode == .send, !useCode, waiting, ui.nowPlaying?.canSend == true else { return nil }
        if let picked { return picked }
        if let prompt = ui.prompt, prompt.id != answered { return prompt }
        return nil
    }

    // MARK: Arming and the camera

    /// Armed while the screen is up in the foreground; the camera runs only while the listener is scanning a code.
    private func sync(_ controller: SongTapController) {
        guard controller.allowed, scenePhase == .active else {
            controller.disarm()
            stopCamera()
            return
        }
        controller.arm(mode)
        cameraStatus = SongTapCameraAccess.current()
        if mode == .receive, scanning, cameraStatus == .allowed {
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
                // The one place Bluetooth is asked for: arming the radio is what shows the system's question, the first time.
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

    // MARK: Bluetooth

    /// What is wrong with Bluetooth, and the one button that helps. Nothing when it works; the code route is always there.
    @ViewBuilder
    private func bluetoothCard(_ ui: SongTapUiState) -> some View {
        let text: String? = switch ui.bluetooth {
        case .noPermission: SongTapStrings.btPermission
        case .bluetoothOff: SongTapStrings.btOff
        case .unsupported: SongTapStrings.btUnsupported
        case .idle, .active: nil
        }
        if let text {
            GlassCard(cornerRadius: 24, tint: theme.tertiaryContainer) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onTertiaryContainer)
                    if ui.bluetooth != .unsupported {
                        // iOS asks once; after that the way back is the app's page in Settings.
                        textButton(SongTapStrings.openSettings, id: "songTap.bluetoothSettings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("songTap.bluetoothCard")
        }
    }

    /// The line under the song while Bluetooth is looking for the other phone.
    private func statusLine(_ ui: SongTapUiState) -> String? {
        guard ui.bluetooth == .active else { return nil }
        switch ui.phase {
        case .saved where ui.role == .send: return SongTapStrings.statusSent
        case .armed: return SongTapStrings.statusLooking
        case .found: return SongTapStrings.statusFound
        case .near: return SongTapStrings.statusNear
        default: return nil
        }
    }

    // MARK: Send

    @ViewBuilder
    private func sendContent(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        if let playing = ui.nowPlaying {
            SongTapBeamArtwork(artUrl: playing.artUrl, beamRole: ui.beamRole, beamStartMs: ui.beamStartMs, reduced: ui.beamReduced,
                               rootHeight: rootHeight, size: 248)
                .padding(.top, 8)
            VStack(spacing: 2) {
                Text(playing.title)
                    .pixlFont(.titleLarge)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(playing.artist)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            if !playing.canSend {
                Text(SongTapStrings.sendCant)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                let armed = ui.session.target != 0 && ui.phase == .offered
                let status = statusLine(ui)
                if armed {
                    armedCard(controller, ui)
                } else {
                    Text(status ?? SongTapStrings.sendHint)
                        .pixlFont(.titleSmall)
                        .foregroundStyle(status != nil ? theme.primary : theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .animation(PixlMotion.state, value: status)
                }
                if ui.role == .send, ui.phase == .transferring, ui.beamRole == nil, ui.session.beamDone {
                    Text(SongTapStrings.dropWaiting(ui.peerName ?? SongTapStrings.dropOtherPhone))
                        .pixlFont(.titleSmall)
                        .foregroundStyle(theme.primary)
                }
                let waitingPhase = ui.phase == .armed || ui.phase == .found || ui.phase == .near
                if !armed, !useCode, waitingPhase, ui.bluetooth == .active {
                    nearbyList(ui)
                }
                if armed {
                    EmptyView()
                } else if useCode, let code = ui.code {
                    SongTapQrView(text: code, accessibilityText: SongTapStrings.codeDescription)
                    Text(SongTapStrings.codeHint)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                    plainButton(SongTapStrings.backToTap, id: "songTap.hideCode") {
                        useCode = false
                        controller.hideCode()
                    }
                } else {
                    textButton(SongTapStrings.useCode, id: "songTap.showCode") {
                        useCode = true
                        controller.showCode()
                    }
                }
            }
        } else {
            Text(SongTapStrings.sendNothing)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The phones that advertise as receivers inside the list gate, strongest first. A row is "Close" inside the near gate, "Nearby"
    /// otherwise; a tap on it asks "Song drop to X?".
    private func nearbyList(_ ui: SongTapUiState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SongTapStrings.dropNearbyTitle)
                .pixlFont(.titleSmall)
                .foregroundStyle(theme.primary)
            if ui.nearby.isEmpty {
                Text(SongTapStrings.dropNearbyEmpty)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            ForEach(ui.nearby, id: \.id) { entry in
                Button { picked = entry } label: {
                    GlassCard(cornerRadius: 24, tint: theme.surfaceContainerHigh) {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(theme.primary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .pixlFont(.titleMedium)
                                    .foregroundStyle(theme.onSurface)
                                    .lineLimit(1)
                                Text(entry.near ? SongTapStrings.dropSignalClose : SongTapStrings.dropSignalNearby)
                                    .pixlFont(.bodySmall)
                                    .foregroundStyle(theme.onSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("songTap.nearby.\(entry.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PixlMotion.state, value: ui.nearby.map(\.id))
    }

    /// After a yes: the sender waits for the touch, armed to that one phone.
    private func armedCard(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        GlassCard(cornerRadius: 28, tint: theme.primaryContainer) {
            VStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .accessibilityHidden(true)
                Text(SongTapStrings.dropArmedTitle)
                    .pixlFont(.headlineSmall)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .multilineTextAlignment(.center)
                Text(SongTapStrings.dropArmedTo(ui.peerName ?? SongTapStrings.dropOtherPhone))
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .multilineTextAlignment(.center)
                textButton(SongTapStrings.dropArmedCancel, id: "songTap.cancelDrop") { controller.cancelDrop() }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("songTap.armed")
    }

    // MARK: Receive

    @ViewBuilder
    private func receiveContent(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        if scanning {
            scanner(controller)
            plainButton(SongTapStrings.backToTap, id: "songTap.backToTap") { scanning = false }
        } else {
            ZStack {
                Circle().fill(theme.surfaceContainerHigh)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .accessibilityHidden(true)
            }
            .frame(width: 184, height: 184)
            .padding(.top, 24)
            let status = statusLine(ui)
            Text(status ?? SongTapStrings.receiveHint)
                .pixlFont(.titleSmall)
                .foregroundStyle(status != nil ? theme.primary : theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .animation(PixlMotion.state, value: status)
            textButton(SongTapStrings.scanCode, id: "songTap.scanCode") { scanning = true }
        }
    }

    /// The camera, behind its permission: asked for the first time the listener chooses to scan a code, and nowhere else.
    @ViewBuilder
    private func scanner(_ controller: SongTapController) -> some View {
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

    /// What happened, in one plain card, when the beam is not showing it: the question the first time (Add / Not now), a result
    /// that came without a beam (a slow save), or why it did not work.
    @ViewBuilder
    private func resultCard(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        let phase = ui.phase
        let receiving = ui.role == .receive
        let beamShowsIt = ui.beamRole == .receive
        let showsSong = ui.card != nil && receiving && !beamShowsIt && (phase == .offered || phase == .transferring || phase == .saved)
        let showsText = phase == .failed || phase == .declined || phase == .cancelled || (ui.notice == .invalidCode && phase == .armed)
        if showsSong || showsText {
            GlassCard(cornerRadius: 28, tint: theme.secondaryContainer) {
                VStack(alignment: .leading, spacing: 12) {
                    if showsSong, let card = ui.card {
                        if let from = ui.peerName {
                            Text(SongTapStrings.from(from))
                                .pixlFont(.labelLarge)
                                .foregroundStyle(theme.primary)
                        }
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
