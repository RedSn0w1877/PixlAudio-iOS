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

    @State private var mode: SongTapRole = .send
    @State private var snapshot = SongTapDiagSnapshot()
    @State private var events: [SongTapDiagEvent] = []
    @State private var copied = false

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
                block(SongTapStrings.diagSignal) {
                    line("status", snapshot.status.rawValue)
                    line("following", snapshot.focus.isEmpty ? "-" : snapshot.focus)
                    line("phones heard", String(snapshot.peersSeen))
                    line("signal now", "\(snapshot.rssi) dBm")
                    line("smoothed", "\(snapshot.smoothed) dBm")
                    line("baseline", "\(snapshot.baseline) dBm")
                    line("jump", "\(snapshot.jump) dB   (fires at \(SongTapTuning.jumpDb))")
                    line("held for", snapshot.heldMs < 0 ? "-" : "\(snapshot.heldMs) ms")
                    line("near", snapshot.near ? "yes" : "no")
                    line("connection", snapshot.connection)
                    line("readings", String(snapshot.samples))
                }
                block(SongTapStrings.diagMotion) {
                    line("this phone's last jerk", ageText(snapshot.ownJerkAgeMs))
                    line("other phone's last jerk", ageText(snapshot.peerJerkAgeMs))
                }
                block(SongTapStrings.diagDetector) {
                    line("state", snapshot.detector)
                    line("last tap", snapshot.lastFire)
                    line("session", ui.phase.code)
                }
                block(SongTapStrings.diagTuning) {
                    line("jump", "\(SongTapTuning.jumpDb) dB, hold \(SongTapTuning.holdMs) ms, dwell \(SongTapTuning.dwellMs) ms")
                    line("jerk window", "\(SongTapTuning.impulseWindowMs) ms, at least \(SongTapTuning.jerkMilliG) milli g")
                    line("near", "from \(SongTapTuning.nearEnterDbm) to \(SongTapTuning.nearExitDbm) dBm")
                    line("cooldown", "\(SongTapTuning.cooldownMs) ms")
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
        .onAppear {
            let diag = controller.diagnostics
            diag.onChange = { snapshot = diag.snapshot; events = diag.events }
            diag.setEnabled(true)
            events = diag.events
            sync(controller)
        }
        .onDisappear {
            controller.diagnostics.setEnabled(false)
            controller.disarm()
        }
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

    private func ageText(_ ms: Int64) -> String { ms < 0 ? "none lately" : "\(ms) ms ago" }

    /// The copied log leads with the numbers on screen at that moment.
    private func logText(_ controller: SongTapController) -> String {
        let s = snapshot
        let head = "now: signal \(s.rssi) dBm, smoothed \(s.smoothed), baseline \(s.baseline), jump \(s.jump) dB, held \(s.heldMs) ms, " +
            "near \(s.near), \(s.connection), detector \(s.detector)\n"
        let device = "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return head + controller.diagnostics.copyLog(device: device)
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
