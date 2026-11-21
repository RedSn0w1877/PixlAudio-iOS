import CoreGraphics
import Observation
import PixlLibrary
import SwiftUI
import UIKit

/// Developer mode > Ring code diagnostics (Android `RingCodeDiagnosticsScreen`). Point the camera at a ring code: the picture is what the
/// scanner sees (grey, upright), with the plate's circle, the art circle and the orange start dot it found drawn over it; below are the
/// numbers of the last scan (frame rate, dots matched, Reed-Solomon fixes, erasures), the confidence of every one of the 200 slots, the
/// last 20 results with a "Copy log" button, and the renderer at this phone's own colour in light and dark mode with the contrast
/// figures, so the dots and plate can be judged by eye. It does not arm Song Tap: scanning here never saves a song, and the camera and
/// the picture copies run only while this screen is open.

/// What the screen shows, refreshed from the diagnostics hub at most as often as the hub publishes (five times a second).
@MainActor
@Observable
final class RingDiagModel {
    private(set) var snapshot = RingDiagSnapshot.empty
    private(set) var log: [String] = []
    private(set) var picture: CGImage?
    var cameraFailed = false
    @ObservationIgnored private let hub: RingCodeDiagnostics
    @ObservationIgnored private var pending = false

    init(hub: RingCodeDiagnostics) {
        self.hub = hub
    }

    /// The camera's queue says something changed: one refresh on the main actor, however many scans came meanwhile.
    nonisolated func changed() {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func refresh() {
        let next = hub.snapshot
        if next.serial != snapshot.serial { picture = Self.image(of: next) }
        snapshot = next
        log = hub.log
    }

    private static func image(of s: RingDiagSnapshot) -> CGImage? {
        guard s.previewWidth > 0, s.previewHeight > 0, s.preview.count == s.previewWidth * s.previewHeight,
              let provider = CGDataProvider(data: Data(s.preview) as CFData) else { return nil }
        return CGImage(width: s.previewWidth, height: s.previewHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: s.previewWidth,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct RingCodeDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var model: RingDiagModel?
    @State private var camera: RingCodeCamera?
    @State private var cameraStatus = SongTapCameraAccess.current()
    @State private var copied = false
    @State private var beamAt: Int64 = 0

    /// A made-up song, so the colours can be judged without one: the same code the Android screen draws.
    private static let previewSlots: RingCodeSlots = {
        let bits = RingCodePayloads.encodeSlots(videoId: "dQw4w9WgXcQ", minuteBucket: 12, random: 77) ?? [UInt8](repeating: 0, count: RingCodeLayout.slots)
        return RingCodeSlots(bits: bits, serial: 1)
    }()

    var body: some View {
        let model = self.model ?? RingDiagModel(hub: env.songTap.ringDiagnostics)
        let snap = model.snapshot
        SettingsScaffold(title: SongTapStrings.ringDiagTitle, screenID: "ringCodeDiagnostics", spacing: 12) {
            block(SongTapStrings.ringDiagCamera) {
                Text(SongTapStrings.ringDiagCameraHint)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                cameraContent(model)
            }
            block(SongTapStrings.ringDiagNumbers) {
                monoLine(SongTapStrings.ringDiagStats(fps: snap.framesPerSecond, scans: snap.scansPerSecond,
                                                      millis: RingText.millis(snap.scanMicros), width: snap.frameWidth, height: snap.frameHeight))
                monoLine(SongTapStrings.ringDiagFound(plate: snap.found, marker: snap.markerFound, matched: snap.matched,
                                                      candidates: snap.candidates))
                monoLine(SongTapStrings.ringDiagRs(fixed: snap.rsCorrected, erasures: snap.erasures,
                                                   residual: RingText.fixed(snap.residualPx, decimals: 2)))
                monoLine(SongTapStrings.ringDiagOutcome(snap.outcome.isEmpty ? "-" : snap.outcome))
                if snap.tooSlow {
                    Text(SongTapStrings.ringDiagTooSlow)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.error)
                }
            }
            block(SongTapStrings.ringDiagSlots) {
                Text(SongTapStrings.ringDiagSlotsHint)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                slotMap(snap)
            }
            block(SongTapStrings.ringDiagResults) {
                if model.log.isEmpty { monoLine(SongTapStrings.ringDiagResultsEmpty) }
                ForEach(Array(model.log.reversed().enumerated()), id: \.offset) { _, line in monoLine(line) }
                HStack(spacing: 8) {
                    chip(copied ? SongTapStrings.diagCopied : SongTapStrings.diagCopy) {
                        let device = "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                        UIPasteboard.general.string = env.songTap.ringDiagnostics.copyText(device: device)
                        copied = true
                    }
                }
                .padding(.top, 8)
            }
            colourPreview
            Spacer().frame(height: 24)
        }
        .onAppear {
            let hub = env.songTap.ringDiagnostics
            let made = model
            self.model = made
            hub.onChange = { [weak made] in made?.changed() }
            hub.setEnabled(true)
            syncCamera(made)
        }
        .onDisappear {
            let hub = env.songTap.ringDiagnostics
            hub.onChange = nil
            hub.setEnabled(false)
            camera?.stop()
        }
        .onChange(of: scenePhase) { _, _ in syncCamera(self.model) }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            if !Task.isCancelled { copied = false }
        }
        .task(id: beamAt) {
            guard beamAt != 0 else { return }
            try? await Task.sleep(for: .milliseconds(2_800))
            if !Task.isCancelled { beamAt = 0 }
        }
    }

    // MARK: The camera

    @ViewBuilder
    private func cameraContent(_ model: RingDiagModel) -> some View {
        if !RingCodeCamera.exists {
            Text(SongTapStrings.ringNoCamera)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurface)
        } else {
            switch cameraStatus {
            case .allowed:
                if model.cameraFailed {
                    Text(SongTapStrings.ringCameraFailed)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.error)
                } else {
                    scanPicture(model)
                }
            case .notAsked:
                Text(SongTapStrings.cameraNeeded)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                chip(SongTapStrings.allowCamera) {
                    Task {
                        _ = await SongTapCameraAccess.request()
                        syncCamera(self.model)
                    }
                }
            case .blocked:
                Text(SongTapStrings.cameraBlocked)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                chip(SongTapStrings.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    /// The camera runs without a preview of its own: the picture on the screen is the one the scanner works from.
    private func syncCamera(_ model: RingDiagModel?) {
        cameraStatus = SongTapCameraAccess.current()
        guard let model, scenePhase == .active, cameraStatus == .allowed, RingCodeCamera.exists else {
            camera?.stop()
            return
        }
        let hub = env.songTap.ringDiagnostics
        let active = camera ?? RingCodeCamera(sink: Self.sink(hub: hub, model: model))
        camera = active
        model.cameraFailed = false
        active.start()
    }

    /// Scans go to the diagnostics only: nothing here looks a song up or touches the Song Tap session.
    private static func sink(hub: RingCodeDiagnostics, model: RingDiagModel) -> RingCodeCamera.Sink {
        var sink = RingCodeCamera.Sink()
        sink.onFrame = { now in hub.onFrame(nowMs: now) }
        sink.onScan = { frame, result, details, rotation, now in
            hub.record(frame: frame, result: result, diagnostics: details, rotationDegrees: rotation, nowMs: now)
        }
        sink.onSlow = { hub.onSlow() }
        sink.onFailed = { [weak model] in Task { @MainActor in model?.cameraFailed = true } }
        return sink
    }

    /// The last picture the scanner worked from, with what it found drawn over it.
    private func scanPicture(_ model: RingDiagModel) -> some View {
        let snap = model.snapshot
        let picture = model.picture
        let aspect = snap.previewWidth > 0 ? CGFloat(snap.previewWidth) / CGFloat(snap.previewHeight) : 3.0 / 4.0
        return Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            if let picture { context.draw(Image(decorative: picture, scale: 1), in: CGRect(origin: .zero, size: size)) }
            if snap.found {
                let c = CGPoint(x: snap.centreX * size.width, y: snap.centreY * size.height)
                let outline = snap.radius * size.width
                // The outline's outer edge, the art circle inside it and the plate's reach outside it.
                func ring(_ radius: CGFloat, _ color: Color, _ width: CGFloat) {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(color), lineWidth: width)
                }
                ring(outline, Color(red: 0.22, green: 0.83, blue: 0.33), 2)
                ring(outline * CGFloat(RingCodeLayout.artRadius) / CGFloat(RingCodeLayout.bezelOuter), Color(red: 0.25, green: 0.78, blue: 0.89), 2)
                ring(outline * 1000 / CGFloat(RingCodeLayout.bezelOuter), Color.white.opacity(0.35), 1)
            }
            if snap.markerFound {
                let m = CGPoint(x: snap.markerX * size.width, y: snap.markerY * size.height)
                context.stroke(Path(ellipseIn: CGRect(x: m.x - 9, y: m.y - 9, width: 18, height: 18)),
                               with: .color(Color(red: 1, green: 0.48, blue: 0.1)), lineWidth: 3)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    /// All 200 slots as the plate lays them out, each dot as bright as the scanner was sure of it (big dots large, small dots small).
    private func slotMap(_ snap: RingDiagSnapshot) -> some View {
        let seen = snap.confidence.contains { $0 > 0 }
        return Canvas { context, size in
            let half = min(size.width, size.height) / 2
            let unit = half / 1000
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for slot in 0..<RingCodeLayout.slots {
                let ring = RingCodeLayout.ringOf(slot)
                let a = Double(RingCodeLayout.indexInRing(slot)) / Double(RingCodeLayout.ringSlots[ring]) * 2 * Double.pi
                let r = CGFloat(RingCodeLayout.ringRadius[ring]) * unit
                let big = snap.bits[slot] != 0
                let conf = snap.confidence[slot]
                let colour: Color
                if !seen { colour = Color.gray.opacity(0.4) } else if conf == 0 { colour = Color(red: 0.9, green: 0.28, blue: 0.3) } else if conf < 40 {
                    colour = Color(red: 0.96, green: 0.65, blue: 0.14)
                } else {
                    colour = Color(red: 0.19, green: 0.64, blue: 0.42)
                }
                let radius = CGFloat(big ? RingCodeLayout.bigRadius : RingCodeLayout.smallRadius) * unit
                let x = c.x + r * CGFloat(sin(a))
                let y = c.y - r * CGFloat(cos(a))
                var dot = context
                dot.opacity = seen ? 0.35 + 0.65 * min(max(Double(conf) / 100, 0), 1) : 1
                dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(colour))
            }
            let markerR = CGFloat(RingCodeLayout.markerRadius) * unit
            let markerY = c.y - CGFloat(RingCodeLayout.markerRadiusAt) * unit
            context.fill(Path(ellipseIn: CGRect(x: c.x - markerR, y: markerY - markerR, width: markerR * 2, height: markerR * 2)),
                         with: .color(Color(argb: UInt32(bitPattern: RingCodeLayout.markerArgb))))
        }
        .aspectRatio(1, contentMode: .fit)
        .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: The colours on this phone

    /// The renderer at this phone's colour, light and dark side by side, with the contrast figures, and a button that plays the beam.
    private var colourPreview: some View {
        let pair = env.theme.accentPair
        return block(SongTapStrings.ringDiagPreview) {
            Text(SongTapStrings.ringDiagPreviewHint)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
            HStack(alignment: .top, spacing: 8) {
                previewColumn(SongTapStrings.ringDiagLight, roles: pair.light, dark: false)
                previewColumn(SongTapStrings.ringDiagDark, roles: pair.dark, dark: true)
            }
            chip(SongTapStrings.ringDiagPlayBeam) { beamAt = currentTimeMillis() + 150 }
        }
    }

    private func previewColumn(_ title: String, roles: ColorRoles, dark: Bool) -> some View {
        let palette = RingPalettes.palette(for: roles.primary)
        let colours = ThemeColors(roles: roles, isDark: dark)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
            RingCodeView(slots: Self.previewSlots, palette: palette, beamStartMs: dark ? 0 : beamAt, rootHeight: 800,
                         pillText: dark ? nil : SongTapStrings.ringSent) {
                Rectangle().fill(Color(red: 0.55, green: 0.43, blue: 0.25))
            }
            .padding(8)
            .background(dark ? Color(red: 0.08, green: 0.07, blue: 0.09) : Color(red: 1, green: 0.98, blue: 1),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.appTheme, colours)
            Text(SongTapStrings.ringDiagContrast(dot: AccentPalette.hex(argb: palette.dot), plate: AccentPalette.hex(argb: palette.plate),
                                                 contrast: RingText.fixed(palette.contrast, decimals: 1), tone: Int(palette.dotTone)))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.onSurface)
            if palette.clamped {
                Text(SongTapStrings.ringDiagDarkened)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pieces

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
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.primary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(theme.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
