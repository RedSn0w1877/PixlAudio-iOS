import PixlLyrics
import SwiftUI
import UniformTypeIdentifiers

/// Preview (Android `SyncPreviewScreen`, spec §2.7): the real result in the same karaoke renderer as the lyrics screen
/// (`KaraokeLyricsView` with its own driver on the editor's clock), over the same artwork, with the earlier / later
/// nudge, Fix a line, Save, Share and Keep tapping in a glass panel.
struct SyncPreviewScreen: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette
    let brightArt: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var driver = LyricsDriver()
    @State private var showShare = false
    @State private var exportDocument: LyricsTextDocument?
    @State private var exportTTML = false
    @State private var fileMessage: String?

    private var appearance: KaraokeLyricsAppearance {
        // The lyrics screen's own preferences, so what the user approves is exactly what the lyrics screen will show.
        let preferences = env.lyricsController.preferences
        let prefs = LyricsAppearancePrefs(
            alignment: preferences.alignment,
            showTranslation: preferences.showTranslation,
            showRomanization: preferences.showRomanization,
            animatedBlurEnabled: settings.lyrics.animatedBlurEnabled,
            disableBlurAllOver: preferences.disableBlurAllOver,
            blurStrength: Float(settings.lyrics.animatedBlurStrength),
            highContrast: contrast == .increased)
        return prefs.toAppearance(textSize: nil, brightArt: brightArt)
    }

    var body: some View {
        VStack(spacing: 0) {
            SyncTopBar(title: session.title, palette: palette, onClose: session.requestClose, speed: session.speed,
                       onSpeedChange: session.setSpeed)
                .padding(.horizontal, 16)
            ZStack(alignment: .top) {
                if let preview = session.preview {
                    KaraokeLyricsView(
                        prepared: preview.prepared, songKey: session.songId, driver: driver, appearance: appearance,
                        reducedMotion: reduceMotion, topInset: 0, topFadeLength: 48, bottomInset: 0,
                        bottomFadeLength: 48, footer: nil,
                        onSeekLine: { line in session.onPreviewLineTap(preparedIndex: line.index, lineStartMs: line.startMs) },
                        onInteraction: {})
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if session.lineSelectMode {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text(SyncStrings.fixLineHint)
                            .pixlFont(.custom(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(palette.accentGlass(interactive: false), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.lineSelectMode)

            SyncPreviewPanel(session: session, palette: palette, onShare: { showShare = true })
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .overlay(alignment: .top) {
            if let fileMessage {
                Text(fileMessage)
                    .pixlFont(.custom(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .glassEffect(palette.chipGlass(interactive: false), in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: fileMessage) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.fileMessage = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: fileMessage)
        .accessibilityIdentifier("sync.preview")
        .onAppear(perform: startDriver)
        .onDisappear { driver.stop() }
        .onChange(of: session.isPlaying) { _, playing in driver.setPlaying(playing) }
        .alert(SyncStrings.share, isPresented: $showShare) {
            Button(SyncStrings.shareLrc) { export(ttml: false) }
            Button(SyncStrings.shareTtml) { export(ttml: true) }
            Button(SyncStrings.cancel, role: .cancel) {}
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument,
                      contentType: exportTTML ? (UTType(filenameExtension: "ttml", conformingTo: .xml) ?? .xml) : .plainText,
                      defaultFilename: session.exportFileName(ttml: exportTTML)) { result in
            switch result {
            case .success: fileMessage = SyncStrings.fileSaved
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { fileMessage = SyncStrings.fileFailed }
            }
        }
    }

    private func startDriver() {
        let session = self.session
        driver.positionProvider = { session.positionMs() }
        if let frozen = session.frozenPositionMs { driver.frozenPositionMs = frozen }
        driver.setPlaying(session.isPlaying)
        driver.start()
    }

    /// Pick a place for the .lrc / .ttml file, then write it (Android `rememberLyricsFileExporter`).
    private func export(ttml: Bool) {
        Task {
            guard let text = await session.exportText(ttml: ttml) else {
                fileMessage = SyncStrings.fileFailed
                return
            }
            exportTTML = ttml
            exportDocument = LyricsTextDocument(text: text)
        }
    }
}

/// The bottom panel (Android `PreviewPanel`): clear glass, 32 pt corners, 16 pt padding, rows 12 pt apart. Its buttons
/// are fills (no glass on glass) except Save, the primary action.
private struct SyncPreviewPanel: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette
    let onShare: () -> Void

    var body: some View {
        ZStack {
            if session.lineSelectMode {
                HStack(spacing: 0) {
                    Text(SyncStrings.fixLineHint)
                        .pixlFont(.custom(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { session.setLineSelectMode(false) } label: {
                        Text(SyncStrings.cancel)
                            .pixlFont(.labelLarge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(SyncStrings.previewTimingQ)
                        .pixlFont(.custom(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    SyncNudgeControl(nudgeMs: session.draft?.nudgeMs ?? 0, palette: palette, onNudge: session.nudge)
                    HStack(spacing: 10) {
                        EditorButton(palette: palette, onPanel: true, fillWidth: true,
                                     action: { session.setLineSelectMode(true) }) { color in
                            Image(systemName: "pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(color)
                            Spacer().frame(width: 6)
                            EditorButtonText(text: SyncStrings.fixLine, color: color, bold: false)
                        }
                        .accessibilityIdentifier("sync.fixLine")
                        EditorButton(palette: palette, onPanel: true, fillWidth: true, action: session.keepTapping) { color in
                            Image(systemName: "hand.tap")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(color)
                            Spacer().frame(width: 6)
                            EditorButtonText(text: SyncStrings.keepTapping, color: color, bold: false)
                        }
                    }
                    HStack(spacing: 10) {
                        EditorButton(palette: palette, onPanel: true, horizontalPadding: 0, action: onShare) { color in
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 56)
                        }
                        .accessibilityLabel(SyncStrings.share)
                        .accessibilityIdentifier("sync.share")
                        EditorButton(palette: palette, prominent: true, enabled: !session.isSaving, fillWidth: true,
                                     action: session.save) { color in
                            if session.isSaving {
                                ProgressView().controlSize(.small).tint(color).frame(width: 18, height: 18)
                                Spacer().frame(width: 10)
                                EditorButtonText(text: SyncStrings.saving, color: color)
                            } else {
                                EditorButtonText(text: SyncStrings.save, color: color)
                            }
                        }
                        .accessibilityIdentifier("sync.save")
                    }
                    if session.preview?.hasRoughLines == true {
                        Text("≈  " + SyncStrings.rough)
                            .pixlFont(.custom(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: session.lineSelectMode)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(palette.panelGlass, in: SyncShapes.panel)
    }
}

/// "‹ Earlier | +40 ms | Later ›": each press moves every word by 20 ms (Android `NudgeControl`, a 52 pt capsule fill).
private struct SyncNudgeControl: View {
    let nudgeMs: Int
    let palette: SyncEditorPalette
    let onNudge: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            half(label: SyncStrings.earlier, leading: true) { onNudge(-1) }
                .accessibilityIdentifier("sync.earlier")
            Text(SyncStrings.nudgeValue(nudgeMs))
                .pixlFont(.custom(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .contentTransition(.numericText(value: Double(nudgeMs)))
                .animation(.snappy(duration: 0.2), value: nudgeMs)
            half(label: SyncStrings.later, leading: false) { onNudge(1) }
                .accessibilityIdentifier("sync.later")
        }
        .frame(height: 52)
        .background(palette.panelButtonFill, in: Capsule())
        .clipShape(Capsule())
    }

    private func half(label: String, leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if leading { Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)) }
                Text(label).pixlFont(.custom(size: 15, weight: .medium))
                if !leading { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
    }
}
