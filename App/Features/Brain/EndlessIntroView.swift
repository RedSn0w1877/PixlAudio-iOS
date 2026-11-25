import PixlLibrary
import SwiftUI

/// The introduction of Endless Listening, redesign batch 3 (Android `EndlessIntroScreen`, mockups AndroidEndlessIntro1/2/3; 390 × 844,
/// 1 dp = 1 pt). First open of the Home entry shows it; a long press on the entry, the station's options and Settings › Endless Listening ›
/// How it works replay it. Android's layout; Material fills become Liquid Glass (the circle buttons, the Next / Start pill), the stage's
/// illustrations stay drawings (fills).
///
///   header   safe area + 20 pt, 16 pt gutter, 48 pt: Close (page 1) or Back (pages 2-3) as a neutral glass circle (22 dp icon);
///            "Skip" (pages 1-2) 15 pt medium in primary, 18/14 pt padding: skips straight to the station.
///   stage    390 × 340 pt, 28 pt under the header, scaled to the width (0.7…1.2×). Page 1: the figure eight (34 pt round stroke,
///            primaryContainer) with four shapes riding it, a quarter lap apart, 14 s a lap, tilt ±12°. Page 2: the host's note cards
///            fanned (−7 / 4 / −3°), dealt in. Page 3: you ask, the host answers, the chips pop in.
///   words    24 pt gutter, 34 pt under the stage, 14 pt apart: eyebrow 14/20 semibold 0.4 in the page colour, title 48 heavy (line one
///            expanded −1.6, line two compressed −0.8 in the page colour), body 16/24 onSurfaceVariant.
///   footer   24 pt gutter, 32 pt from the bottom, 64 pt: dots 6 pt apart (active 28 × 8 in the page colour, others 8 × 8 outlineVariant)
///            and the 64 pt pill (32 pt corners, 30/26 pt padding, 17 semibold, 22 dp arrow); on page 3 the pill fills the row.
///
/// Performance: page 1's loop is one `TimelineView` that moves four shapes by transform (the path is built once per size) and runs only on
/// page 1, on screen, with the app active and without Reduce Motion. Pages 2-3 deal their cards in with one spring each, transform only.
struct EndlessIntroView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var page = 0
    @State private var onScreen = false

    private static let pages = 3

    var body: some View {
        let tone = pageTone(page)
        ZStack(alignment: .top) {
            theme.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(0 ..< Self.pages, id: \.self) { p in
                        VStack(spacing: 0) {
                            Spacer().frame(height: 28)
                            IntroStage {
                                switch p {
                                case 0: InfinityArt(animates: onScreen && page == 0 && scenePhase == .active && !reduceMotion)
                                case 1: NotesArt(dealt: page == 1, still: reduceMotion)
                                default: SteerArt(dealt: page == 2, still: reduceMotion)
                                }
                            }
                            Spacer().frame(height: 34)
                            IntroWords(page: p, tone: pageTone(p), dealt: page == p, still: reduceMotion)
                            Spacer(minLength: 0)
                        }
                        .tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                footer(tone)
            }
            .frame(maxWidth: 600)
        }
        .accessibilityIdentifier("screen.endlessIntro")
        .accessibilityAction(.escape) { if page > 0 { go(page - 1) } else { close() } }
        .pixlHaptic(.selection, trigger: page)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    /// Page colours: 1 primary, 2 tertiary, 3 secondary, with their on-colours.
    private func pageTone(_ p: Int) -> (color: Color, on: Color) {
        switch p {
        case 0: (theme.primary, theme.onPrimary)
        case 1: (theme.tertiary, theme.onTertiary)
        default: (theme.secondary, theme.onSecondary)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Group {
                if page == 0 {
                    GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.introClose),
                                      size: 48, iconSize: 18, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                      action: close)
                        .accessibilityIdentifier("endless.intro.close")
                } else {
                    GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.back),
                                      size: 48, iconSize: 18, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                      action: { go(page - 1) })
                        .accessibilityIdentifier("endless.intro.back")
                }
            }
            Spacer(minLength: 0)
            if page < Self.pages - 1 {
                Button(action: start) {
                    Text(verbatim: HomeRedesignStrings.introSkip)
                        .pixlFont(.custom(size: 15, weight: .medium, lineHeight: 20))
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(.rect(cornerRadius: 24))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                .accessibilityIdentifier("endless.intro.skip")
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    private func footer(_ tone: (color: Color, on: Color)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return HStack(spacing: 20) {
            dots(tone.color)
            if page < Self.pages - 1 {
                Spacer(minLength: 0)
                Button { go(page + 1) } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: HomeRedesignStrings.introNext)
                            .pixlFont(.custom(size: 17, weight: .semibold, lineHeight: 22))
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundStyle(tone.on)
                    .padding(.leading, 30)
                    .padding(.trailing, 26)
                    .frame(height: 64)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: shape, tint: tone.color.opacity(GlassTint.prominent), interactive: true)
                .accessibilityIdentifier("endless.intro.next")
            } else {
                Button(action: start) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                        Text(verbatim: EndlessStrings.introStart)
                            .pixlFont(.custom(size: 17, weight: .semibold, lineHeight: 22))
                    }
                    .foregroundStyle(tone.on)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: shape, tint: tone.color.opacity(GlassTint.prominent), interactive: true)
                .accessibilityIdentifier("endless.intro.start")
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .animation(reduceMotion ? nil : PixlMotion.state, value: page)
    }

    private func dots(_ color: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(0 ..< Self.pages, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(i == page ? color : theme.outlineVariant)
                    .frame(width: i == page ? 28 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EndlessStrings.introPage(page + 1, of: Self.pages))
    }

    private func go(_ target: Int) {
        let clamped = min(max(target, 0), Self.pages - 1)
        if reduceMotion { page = clamped } else { withAnimation(PixlMotion.state) { page = clamped } }
    }

    /// "Skip" and "Start listening": the station starts (or is picked up) and its screen opens in place of the introduction.
    private func start() {
        env.endless.markIntroSeen()
        env.endless.introReturnsToStation = false
        if !env.endless.isActive { env.brainActions.startEndless() }
        router.present(AppCover.endlessStation)
    }

    /// Close: seen; back to the station when it was opened from there, else back to where it came from.
    private func close() {
        env.endless.markIntroSeen()
        if env.endless.introReturnsToStation {
            env.endless.introReturnsToStation = false
            router.present(AppCover.endlessStation)
        } else {
            router.dismissCover()
        }
    }
}

// MARK: - Stage

/// The 390 × 340 pt stage of the frames, scaled to the width the phone has (0.7…1.2×).
private struct IntroStage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(proxy.size.width / 390, 0.7), 1.2)
            content()
                .frame(width: 390, height: 340, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: 340)
        }
        .frame(height: 340)
    }
}

/// The words under the stage (Android `IntroWords`): eyebrow, the two-cut title, the body; dealt in like the setup flow.
private struct IntroWords: View {
    let page: Int
    let tone: (color: Color, on: Color)
    let dealt: Bool
    let still: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        let text = HomeRedesignStrings.introPages[min(page, 2)]
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: HomeRedesignStrings.endlessEyebrow)
                .pixlFont(.custom(size: 14, weight: .semibold, lineHeight: 20, tracking: 0.4))
                .foregroundStyle(tone.color)
                .dealtIn(dealt, index: 0, still: still)
            VStack(alignment: .leading, spacing: 0) {
                TwoToneTitle(wide: text.a, accent: "", size: 48, tracking: -1.6, lines: 1)
                    .minimumScaleFactor(0.7)
                TwoToneTitle(wide: "", accent: text.b, size: 48, tracking: -0.8, accentColor: tone.color, lines: 1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text.a + " " + text.b))
            .accessibilityAddTraits(.isHeader)
            .dealtIn(dealt, index: 1, still: still)
            Text(verbatim: text.body)
                .pixlFont(.custom(size: 16, lineHeight: 24))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .dealtIn(dealt, index: 2, still: still)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }
}

private extension View {
    /// Dealt in with the setup flow's spring, 0.12 s apart (transform and opacity only); still with Reduce Motion.
    func dealtIn(_ dealt: Bool, index: Int, still: Bool, distance: CGFloat = 24) -> some View {
        opacity(dealt || still ? 1 : 0)
            .offset(y: dealt || still ? 0 : distance)
            .animation(still ? nil : .spring(response: 0.5, dampingFraction: 0.82).delay(dealt ? Double(index) * 0.12 : 0),
                       value: dealt)
    }
}

// MARK: - Page 1: the infinity loop

/// The figure eight of page 1 in the 390 × 340 stage: centre (195, 170), half width 167, half height 70; x = cx + a sin t, y = cy + b sin 2t.
private enum Loop {
    static let cx = 195.0, cy = 170.0, a = 167.0, b = 70.0
    static let lapSeconds = 14.0

    static func point(_ t: Double) -> CGPoint { CGPoint(x: cx + a * sin(t), y: cy + b * sin(2 * t)) }

    /// The track, built once.
    static let path: Path = {
        var path = Path()
        let steps = 96
        for i in 0 ... steps {
            let p = point(Double(i) / Double(steps) * 2 * .pi)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }()
}

/// Page 1: four shapes riding the loop a quarter lap apart (Flower 120 tertiary, SoftBurst 64 secondaryContainer, Clover4 110 secondary,
/// Cookie9 96 primary with a play icon), tilted ±12°.
private struct InfinityArt: View {
    let animates: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Loop.path.stroke(theme.primaryContainer, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
            TimelineView(.animation(paused: !animates)) { context in
                let phase = animates
                    ? 0.08 + context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Loop.lapSeconds) / Loop.lapSeconds
                    : 0.08
                ZStack(alignment: .topLeading) {
                    rider(phase, 0.00, 120, .flower, theme.tertiary, EmptyView())
                    rider(phase, 0.25, 64, .softBurst, theme.secondaryContainer, EmptyView())
                    rider(phase, 0.50, 110, .clover4, theme.secondary, EmptyView())
                    rider(phase, 0.75, 96, .cookie9, theme.primary,
                          Image(systemName: "play.fill")
                              .font(.system(size: 32, weight: .semibold))
                              .foregroundStyle(theme.onPrimary))
                }
            }
        }
        .frame(width: 390, height: 340, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func rider<Content: View>(_ phase: Double, _ offset: Double, _ size: CGFloat, _ kind: BadgeShapeKind, _ color: Color,
                                      _ content: Content) -> some View {
        let t = (phase + offset) * 2 * .pi
        let p = Loop.point(t)
        return content
            .frame(width: size, height: size)
            .background(ExpressiveBadgeShape(kind).fill(color))
            .rotationEffect(.degrees(cos(t) * 12))
            .position(x: p.x, y: p.y)
    }
}

// MARK: - Page 2: the host's notes

private struct NotesArt: View {
    let dealt: Bool
    let still: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ExpressiveBadgeShape(.cookie9).fill(theme.surfaceContainerHigh)
                .frame(width: 300, height: 300)
                .offset(x: 45, y: 20)
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(theme.secondaryContainer)
                .frame(width: 250, height: 96)
                .rotationEffect(.degrees(-7))
                .dealtIn(dealt, index: 0, still: still, distance: 48)
                .offset(x: 60, y: 56)
            HStack(alignment: .top, spacing: 12) {
                HostBadge(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: HomeRedesignStrings.artUpNext)
                        .pixlFont(.custom(size: 12, weight: .bold, lineHeight: 16, tracking: 0.4))
                    Text(verbatim: HomeRedesignStrings.artNote1)
                        .pixlFont(.custom(size: 15, lineHeight: 20))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .padding(16)
            .frame(width: 270, alignment: .leading)
            .background(theme.tertiaryContainer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .rotationEffect(.degrees(4))
            .dealtIn(dealt, index: 1, still: still, distance: 48)
            .offset(x: 56, y: 120)
            Text(verbatim: HomeRedesignStrings.artNote2)
                .pixlFont(.custom(size: 14, lineHeight: 20))
                .foregroundStyle(theme.onPrimaryContainer)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(width: 230, alignment: .leading)
                .background(theme.primaryContainer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .rotationEffect(.degrees(-3))
                .dealtIn(dealt, index: 2, still: still, distance: 48)
                .offset(x: 82, y: 232)
        }
        .frame(width: 390, height: 340, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Page 3: steer it

private struct SteerArt: View {
    let dealt: Bool
    let still: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ExpressiveBadgeShape(.softBurst).fill(theme.secondaryContainer)
                .frame(width: 260, height: 260)
                .offset(x: 65, y: 40)
            Text(verbatim: HomeRedesignStrings.artAsk)
                .pixlFont(.custom(size: 16, lineHeight: 22))
                .foregroundStyle(theme.onPrimaryContainer)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(theme.primaryContainer,
                            in: UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, bottomTrailingRadius: 6,
                                                       topTrailingRadius: 24, style: .continuous))
                .frame(maxWidth: 220, alignment: .trailing)
                .dealtIn(dealt, index: 0, still: still)
                .frame(width: 390 - 28, alignment: .trailing)
                .offset(y: 36)
            HStack(spacing: 10) {
                HostBadge(size: 32)
                Text(verbatim: HomeRedesignStrings.artReply)
                    .pixlFont(.custom(size: 15, lineHeight: 20))
                    .foregroundStyle(theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .background(theme.surfaceContainerHigh,
                        in: UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 6, bottomTrailingRadius: 24,
                                                   topTrailingRadius: 24, style: .continuous))
            .frame(maxWidth: 250, alignment: .leading)
            .dealtIn(dealt, index: 1, still: still)
            .offset(x: 28, y: 116)
            HStack(spacing: 8) {
                chip(HomeRedesignStrings.artChip1, theme.secondary, theme.onSecondary).dealtIn(dealt, index: 2, still: still)
                chip(HomeRedesignStrings.artChip2, theme.tertiaryContainer, theme.onTertiaryContainer)
                    .dealtIn(dealt, index: 3, still: still)
                chip(HomeRedesignStrings.artChip3, theme.secondaryContainer, theme.onSecondaryContainer)
                    .dealtIn(dealt, index: 4, still: still)
            }
            .frame(width: 390 - 80)
            .offset(x: 40, y: 196)
        }
        .frame(width: 390, height: 340, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func chip(_ label: String, _ fill: Color, _ content: Color) -> some View {
        Text(verbatim: label)
            .pixlFont(.custom(size: 14, weight: .semibold, lineHeight: 20))
            .foregroundStyle(content)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
