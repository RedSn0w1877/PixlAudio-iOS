import PixlLibrary
import SwiftUI
import UIKit

/// Developer mode > Song Tap diagnostics (Android `SongTapDiagnosticsScreen`): the live numbers behind the tap detector, so the
/// owner can calibrate it on the real phones. The phones touch; this screen shows the signal rise above its baseline, the jerk on
/// either phone, which part of the detector fired and the last 20 events, and "Copy log" puts all of it (and the thresholds) on
/// the clipboard. It arms Song Tap the same way the main screen does, so it works as one of the two phones. The numbers are
/// published only while this screen is open.
struct SongTapDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Router.self) private var router

    @State private var mode: SongTapRole = .send
    @State private var snapshot = SongTapDiagSnapshot()
    @State private var events: [SongTapDiagEvent] = []
    @State private var copied = false
    /// A phone picked from the nearby list, waiting for its "Song drop to X?" answer (the same question the Song Tap screen asks), and
    /// the phone just answered.
    @State private var picked: SongTapNearbyEntry?
    @State private var answered: Int?
    /// "Open Song Tap" was pressed: the Song Tap screen arms itself, so leaving this one for it must not disarm.
    @State private var openingSongTap = false

    private static let marks = ["touching", "1 cm", "3 cm", "10 cm", "30 cm"]

    var body: some View {
        let controller = env.songTap
        let ui = controller.ui
        SettingsScaffold(title: SongTapStrings.diagTitle, screenID: "songTapDiagnostics", spacing: 12) {
            if !ui.allowed {
                Text(SongTapStrings.diagNeedOn)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                modeSwitch(controller)
                if mode == .send { songDropBlock(controller, ui) }
                sensitivityPicker(controller)
                block(SongTapStrings.diagSignal) {
                    line("status", snapshot.status.rawValue)
                    line("following", snapshot.focus.isEmpty ? "-" : snapshot.focus)
                    line("phones heard", String(snapshot.peersSeen))
                    line("signal now", "\(snapshot.rssi) dBm")
                    line("smoothed", "\(snapshot.smoothed) dBm")
                    line("baseline", "\(snapshot.baseline) dBm")
                    line("jump", "\(snapshot.jump) dB   (fires at \(profile.jumpDb))")
                    line("held for", snapshot.heldMs < 0 ? "-" : "\(snapshot.heldMs) ms")
                    line("near", snapshot.near ? "yes" : "no")
                    line("connection", snapshot.connection)
                    line("readings", String(snapshot.samples))
                }
                block(SongTapStrings.diagScale) {
                    line("signal now, raw", "\(snapshot.rssi) dBm")
                    line("offset", "\(snapshot.offsetDb) dB")
                    line("signal now, normalised", "\(snapshot.normalised) dBm")
                    line("smoothed, normalised", "\(snapshot.smoothed) dBm")
                    line("baseline, normalised", "\(snapshot.baseline) dBm")
                    Text(SongTapStrings.diagScaleHint)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .padding(.top, 4)
                }
                block(SongTapStrings.diagGateNow) {
                    line("gate now", snapshot.gate)
                    line("may connect and beam", snapshot.mayConnect ? "yes" : "no")
                    line("shown in the picker", snapshot.listed ? "yes" : "no")
                    line("offer in hand", snapshot.offerInHand ? "yes" : "no")
                    line("radio starts", String(snapshot.radioStarts))
                    if !snapshot.tapNote.isEmpty { line("last ignored tap", snapshot.tapNote) }
                    line("names", snapshot.names.isEmpty ? "-" : snapshot.names)
                    line("advertises", SongTapNames.advertName(SongTapNames.orFallback(controller.name)))
                    line("full name", SongTapNames.orFallback(controller.name))
                }
                block(SongTapStrings.diagMotion) {
                    line("this phone's last jerk", ageText(snapshot.ownJerkAgeMs))
                    line("other phone's last jerk", ageText(snapshot.peerJerkAgeMs))
                }
                block(SongTapStrings.diagDetector) {
                    line("state", snapshot.detector)
                    line("last tap", snapshot.lastFire)
                    line("session", ui.phase.code)
                    line(SongTapStrings.diagPeerTap, snapshot.peerTap)
                }
                block(SongTapStrings.diagTuning) {
                    line(SongTapStrings.diagProfile, profile.code)
                    line("jump", "\(profile.jumpDb) dB, hold \(profile.holdMs) ms, dwell \(profile.dwellMs) ms")
                    line("jerk window", "\(profile.impulseWindowMs) ms, at least \(profile.jerkMilliG) milli g (optional)")
                    line("tap near gate", "in at \(SongTapTuning.nearEnterDbm), out at \(SongTapTuning.nearExitDbm) dBm")
                    line("list gate", "in at \(SongTapTuning.listEnterDbm), out at \(SongTapTuning.listExitDbm) dBm")
                    line(SongTapStrings.diagHoldLevel, "\(SongTapTuning.closeHoldDbm) dBm for \(SongTapTuning.closeHoldMs) ms, again below \(SongTapTuning.closeReleaseDbm)")
                    line("cooldown", "\(profile.cooldownMs) ms")
                    line("advertising power", "set by iOS (cannot be chosen)")
                }

                Text(SongTapStrings.diagMarks)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SongTapStrings.diagMarksHint)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Self.marks, id: \.self) { label in
                            chip(label) { controller.mark(label) }
                        }
                    }
                }

                Text(SongTapStrings.diagEvents)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                eventsCard
                HStack(spacing: 8) {
                    chip(copied ? SongTapStrings.diagCopied : SongTapStrings.diagCopy) {
                        UIPasteboard.general.string = logText(controller)
                        copied = true
                    }
                    chip(SongTapStrings.diagClear) { controller.diagnostics.clear() }
                }
            }
            Spacer().frame(height: 24)
        }
        .songDropAsk(ui: ui, enabled: mode == .send, picked: $picked, answered: $answered, controller: controller)
        .onAppear {
            openingSongTap = false
            controller.nowPlayingChanged(env.playback.current)
            let diag = controller.diagnostics
            diag.onChange = { snapshot = diag.snapshot; events = diag.events }
            diag.setEnabled(true)
            events = diag.events
            sync(controller)
        }
        .onDisappear {
            controller.diagnostics.setEnabled(false)
            if !openingSongTap { controller.disarm() }
        }
        .onChange(of: env.playback.current?.id) { _, _ in controller.nowPlayingChanged(env.playback.current) }
        .onChange(of: scenePhase) { _, _ in sync(controller) }
        .onChange(of: ui.allowed) { _, _ in sync(controller) }
        .onChange(of: mode) { _, new in
            controller.switchRole(new)
            sync(controller)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            if !Task.isCancelled { copied = false }
        }
    }

    /// Armed only while this screen is up in the foreground, like the main screen.
    private func sync(_ controller: SongTapController) {
        if controller.allowed, scenePhase == .active { controller.arm(mode) } else { controller.disarm() }
    }

    /// The profile the live numbers are read against.
    private var profile: SongTapSensitivity { SongTapSensitivity.fromCode(snapshot.profile) }

    private func sensitivityPicker(_ controller: SongTapController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SongTapStrings.sensitivityTitle)
                .pixlFont(.titleSmall)
                .foregroundStyle(theme.onSurface)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SongTapSensitivity.allCases, id: \.self) { value in
                        let selected = controller.sensitivity == value
                        Button { controller.setSensitivity(value) } label: {
                            Text(SongTapStrings.sensitivityName(value))
                                .pixlFont(.labelLarge)
                                .foregroundStyle(selected ? theme.onPrimary : theme.onSurface)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .pixlGlass(in: Capsule(), tint: selected ? theme.primary.opacity(GlassTint.prominent) : nil, interactive: true)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ageText(_ ms: Int64) -> String { ms < 0 ? "none lately" : "\(ms) ms ago" }

    /// The copied log leads with the numbers on screen at that moment.
    private func logText(_ controller: SongTapController) -> String {
        let s = snapshot
        let head = "now: signal \(s.rssi) dBm, smoothed \(s.smoothed), baseline \(s.baseline), jump \(s.jump) dB, held \(s.heldMs) ms, " +
            "near \(s.near), \(s.connection), detector \(s.detector)\n"
        let device = "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return head + controller.diagnostics.copyLog(device: device)
    }

    // MARK: Song Drop

    /// Where taps get their yes. A sender only beams to a phone it said yes to, and a tap with no yes is ignored, so the list of phones
    /// nearby and the "Song drop to X?" question are here too, not only on the Song Tap screen (the question itself is `SongDropAsk`).
    @ViewBuilder
    private func songDropBlock(_ controller: SongTapController, _ ui: SongTapUiState) -> some View {
        let armed = ui.session.target != 0 && ui.phase == .offered
        if armed {
            SongDropArmedCard(peerName: ui.peerName) { controller.cancelDrop() }
        } else {
            block(SongTapStrings.diagYesTitle) {
                Text(snapshot.needsYes ? SongTapStrings.diagSayYesNow : SongTapStrings.diagSayYes)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(snapshot.needsYes ? theme.error : theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                if ui.nowPlaying?.canSend != true {
                    Text(SongTapStrings.diagNothingToSend)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SongDropNearbyList(entries: ui.nearby) { picked = $0 }
                        .padding(.top, 4)
                }
                chip(SongTapStrings.diagOpenSongTap) {
                    openingSongTap = true
                    router.present(AppCover.songTap)
                }
                .accessibilityIdentifier("songTapDiagnostics.openSongTap")
                .padding(.top, 4)
            }
        }
    }

    // MARK: Pieces

    private func modeSwitch(_ controller: SongTapController) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                modePill(SongTapStrings.modeSend, role: .send)
                modePill(SongTapStrings.modeReceive, role: .receive)
            }
        }
    }

    private func modePill(_ title: String, role: SongTapRole) -> some View {
        let selected = mode == role
        return Button {
            if mode != role { mode = role }
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
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: nil, interactive: true)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GlassCard(cornerRadius: 20, tint: theme.surfaceContainerHigh) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.primary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.trailing)
        }
    }

    private var eventsCard: some View {
        GlassCard(cornerRadius: 20, tint: theme.surfaceContainerHigh) {
            VStack(alignment: .leading, spacing: 2) {
                if events.isEmpty {
                    Text("-").font(.system(.footnote, design: .monospaced)).foregroundStyle(theme.onSurfaceVariant)
                }
                let newest = events.last?.tMs ?? 0
                ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, event in
                    let age = newest - event.tMs
                    Text("-\(age / 1000).\(String(format: "%03d", Int(age % 1000))) s  \(event.text)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(theme.onSurface)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
