import PixlLyrics
import PixlModel
import SwiftUI

/// Plain (unsynced) lyrics (spec §1.1, Android `PlainLyricsLine` in a `LazyColumn`): 20 pt medium, white at 0.85,
/// line height 1.35 em, normal scroll, the same edge fade as the karaoke view.
struct PlainLyricsList: View {
    let lines: [String]
    let alignment: String
    let showTranslation: Bool
    let showRomanization: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let textScale: CGFloat

    var body: some View {
        ScrollView {
            LazyVStack(alignment: horizontalAlignment, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    PlainLyricsLine(line: lines[index], alignment: alignment, showTranslation: showTranslation,
                                    showRomanization: showRomanization, textScale: textScale)
                        .padding(.bottom, 16)
                }
            }
            .padding(.top, topInset + LyricsChromeMetrics.topFade)
            .padding(.horizontal, 24)
            .padding(.bottom, bottomInset + LyricsChromeMetrics.bottomFade)
        }
        .scrollIndicators(.hidden)
        .mask {
            StaticEdgeFadeMask(topInset: topInset, topFade: LyricsChromeMetrics.topFade, bottomInset: bottomInset,
                               bottomFade: LyricsChromeMetrics.bottomFade)
        }
        .accessibilityIdentifier("lyrics.plain")
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }
}

private struct PlainLyricsLine: View {
    let line: String
    let alignment: String
    let showTranslation: Bool
    let showRomanization: Bool
    let textScale: CGFloat

    var body: some View {
        let parts = line.components(separatedBy: "\n")
        let primary = parts.first.map(LyricsSheetLogic.sanitizeLyricLineText) ?? ""
        let romanizedScript = MultiLangRomanizer.isScriptThatNeedsRomanization(primary)
        let firstExtraIsRomanization = parts.count > 1 && romanizedScript
            && parts[1].unicodeScalars.contains { (32...126).contains($0.value) }
        let romanization = firstExtraIsRomanization ? LyricsSheetLogic.sanitizeLyricLineText(parts[1]) : ""
        let translation = parts.count > 1
            ? parts.dropFirst(firstExtraIsRomanization ? 2 : 1).map(LyricsSheetLogic.sanitizeLyricLineText).joined(separator: "\n")
            : ""
        let size = 20 * min(max(textScale, 0.6), 2)
        let style = PixlTextStyle.custom(size: size, weight: .medium, lineHeight: size * 1.35, tracking: -0.005 * size)
        let secondary = PixlTextStyle.custom(size: size * 0.75, weight: .regular, lineHeight: size * 0.75 * 1.35)

        VStack(alignment: horizontalAlignment, spacing: 0) {
            if !primary.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(verbatim: primary)
                    .pixlFont(style)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(textAlignment)
                if showRomanization && !romanization.isEmpty {
                    Text(verbatim: romanization)
                        .pixlFont(secondary)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(textAlignment)
                        .padding(.top, 4)
                }
                if showTranslation && !translation.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: translation)
                        .pixlFont(secondary)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(textAlignment)
                        .padding(.top, showRomanization && !romanization.isEmpty ? 2 : 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }
}

/// The plain list's edge fade (`lyricsEdgeFade` with explicit lengths).
private struct StaticEdgeFadeMask: View, Animatable {
    let topInset: CGFloat
    let topFade: CGFloat
    var bottomInset: CGFloat
    let bottomFade: CGFloat

    var animatableData: CGFloat {
        get { bottomInset }
        set { bottomInset = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let h = max(geometry.size.height, 1)
            let r = LyricsEdgeFade(topInset: Float(topInset), topFadeLength: Float(topFade),
                                   bottomFadeLength: Float(bottomFade))
                .resolve(height: Float(h), bottomInset: Float(bottomInset))
            let l0 = clamp(CGFloat(r.topClearEnd) / h)
            let l1 = max(l0, clamp(CGFloat(r.topFadeEnd) / h))
            let l2 = max(l1, clamp(CGFloat(r.bottomFadeStart) / h))
            let l3 = max(l2, clamp(CGFloat(r.bottomEdge) / h))
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: l0),
                                   .init(color: .black, location: l1), .init(color: .black, location: l2),
                                   .init(color: .clear, location: l3), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
}

/// Loading and "no lyrics" states (Android `LyricsStatusContent`). The loader appears only if loading takes 400 ms.
struct LyricsStatusContent: View {
    let isLoading: Bool
    let song: Song?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onFindLyrics: () -> Void
    let onSyncYourself: (() -> Void)?

    @Environment(\.playerTheme) private var theme
    @State private var loaderVisible = false

    var body: some View {
        ScrollView {
            ZStack {
                if isLoading {
                    if loaderVisible {
                        VStack(spacing: 8) {
                            Text("Loading lyrics…")
                                .pixlFont(.titleMedium)
                                .foregroundStyle(.white.opacity(0.85))
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(theme.primaryFixedDim)
                                .frame(width: 100)
                        }
                        .transition(.opacity)
                    }
                } else if let song {
                    noLyricsCard(song)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(.top, topInset + LyricsChromeMetrics.topFade)
            .padding(.horizontal, 24)
            .padding(.bottom, bottomInset + LyricsChromeMetrics.bottomFade)
        }
        .scrollIndicators(.hidden)
        .task(id: isLoading) {
            loaderVisible = false
            guard isLoading else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { loaderVisible = true } }
        }
        .accessibilityIdentifier("lyrics.status")
    }

    /// Android's `InstrumentalRenderAction` card plus "Add lyrics and sync them".
    private func noLyricsCard(_ song: Song) -> some View {
        VStack(spacing: 8) {
            // Stage 14: the real card (render / play the instrumental through TAIS Studio).
            InstrumentalRenderAction(song: song, onFindLyrics: onFindLyrics)
            if let onSyncYourself {
                Button(action: onSyncYourself) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill").font(.system(size: 15, weight: .semibold))
                        Text("Add lyrics and sync them").pixlFont(.labelLarge)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // On the artwork, not on the card: its own clear glass, tinted like the lyrics chrome (2026-10-07).
                .glassEffect(Glass.clear.tint(theme.onPrimary.opacity(GlassTint.playerChrome)).interactive(),
                             in: Capsule())
                .padding(.top, 8)
            }
        }
    }
}
