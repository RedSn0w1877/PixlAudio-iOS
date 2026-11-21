import PixlLibrary
import SwiftUI

/// The introduction of Endless Listening (Android `EndlessIntroScreen`): three pages, shown the first time its card is opened and again from
/// the card's menu and Settings › Endless Listening › How it works. Liquid Glass in the setup's pattern (`SetupView`): a static backdrop, the
/// pages in a paged `TabView`, the dots, and one glass capsule, "Start listening", in the only `GlassEffectContainer` of the screen, with
/// "Not now" as plain text under it.
///
/// Performance: the five bars are one `Canvas` read from one time value, in a `TimelineView` that runs at 30 fps only while the screen is
/// on the display and the app is active, and stands still with Reduce Motion; their colour is the album colours of the first seed, read once
/// (`AlbumSchemeReader`, cached by `ColorExtractor`), static after that. No blur, nothing allocated per frame beyond the five rectangles
/// the canvas fills.
struct EndlessIntroView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var page = 0
    /// The artwork of the first seed, for the bars' colour; nil until read (the theme's primary colour meanwhile).
    @State private var art: String?
    @State private var onScreen = false

    var body: some View {
        let animates = onScreen && scenePhase == .active && !SetupMotion.isStill(reduceMotion: reduceMotion)
        ZStack {
            EndlessIntroBackdrop(art: art)
            VStack(spacing: 0) {
                AlbumSchemeReader(artUri: art) { colors in
                    EndlessBars(color: colors.primary, animates: animates)
                }
                .frame(height: 132)
                .padding(.top, 72)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(EndlessStrings.introBars)
                TabView(selection: $page) {
                    ForEach(Array(EndlessStrings.introPages.enumerated()), id: \.offset) { index, text in
                        EndlessIntroPage(title: text.title, message: text.body).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : PixlMotion.state, value: page)
                dots
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                GlassEffectContainer {
                    SetupFilledButton(title: EndlessStrings.introStart, systemImage: "play.fill", kind: .primary, action: start)
                }
                .accessibilityIdentifier("endless.intro.start")
                .padding(.horizontal, 20)
                .frame(maxWidth: 560)
                Button(action: notNow) {
                    Text(EndlessStrings.introNotNow)
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(minWidth: 120, minHeight: 48)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("endless.intro.notNow")
                .padding(.bottom, 12)
            }
        }
        .accessibilityIdentifier("screen.endlessIntro")
        // VoiceOver's escape gesture is "Not now".
        .accessibilityAction(.escape, notNow)
        .pixlHaptic(.selection, trigger: page)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task { art = await env.endless.firstSeedArt() }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<EndlessIntro.pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? theme.primary : theme.onSurface.opacity(0.18))
                    .frame(width: index == page ? 28 : 10, height: 8)
            }
        }
        .animation(reduceMotion ? nil : PixlMotion.selection, value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EndlessStrings.introPage(page + 1, of: EndlessIntro.pageCount))
    }

    private func start() {
        env.endless.markIntroSeen()
        router.dismissCover()
        env.brainActions.startEndless()
    }

    private func notNow() {
        env.endless.markIntroSeen()
        router.dismissCover()
    }
}

/// One page: the title and the sentence under it, centred.
private struct EndlessIntroPage: View {
    let title: String
    let message: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .pixlFont(.custom(size: 34, weight: .bold, lineHeight: 40))
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 560, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The backdrop: the theme's background and one soft glow of the first seed's colour from the top. Static, so it costs one draw.
private struct EndlessIntroBackdrop: View {
    let art: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            theme.background
            AlbumSchemeReader(artUri: art) { colors in
                RadialGradient(colors: [colors.primary.opacity(0.28), colors.primary.opacity(0)], center: .top,
                               startRadius: 0, endRadius: 520)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Five rounded bars scaled by one value, the time (`EndlessIntro.scale`), drawn in one `Canvas`. `animates` false draws them still.
struct EndlessBars: View {
    let color: Color
    let animates: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let seconds = animates ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0
            Canvas { canvas, size in
                let count = EndlessIntro.barCount
                let gap = size.width * 0.04
                let width = min((size.width - gap * Double(count - 1)) / Double(count), 36)
                let total = width * Double(count) + gap * Double(count - 1)
                let left = (size.width - total) / 2
                for bar in 0..<count {
                    let scale = animates ? EndlessIntro.scale(bar: bar, seconds: seconds) : EndlessIntro.stillScales[bar]
                    let height = size.height * scale
                    let rect = CGRect(x: left + Double(bar) * (width + gap), y: size.height - height, width: width, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
                }
            }
        }
    }
}
