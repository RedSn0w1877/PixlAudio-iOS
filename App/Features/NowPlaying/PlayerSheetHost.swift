import PixlModel
import SwiftUI

/// The player sheet (Android `UnifiedPlayerSheetV2`): one card that rests as the mini player above the bottom bar
/// and morphs into the full player — drag it up (or tap it) to expand, drag the full player down (or swipe in from
/// the leading edge, the iOS stand-in for predictive back) to collapse; both follow the finger and settle with
/// Android's springs.
///
/// The shell puts a `MiniPlayerSlot` where the mini player sits and this host as a sibling above everything; the
/// card interpolates from the slot's frame (16 pt side insets, 64 pt tall, 32 pt top / 10 pt bottom corners) to the
/// whole screen (no corners) with the expansion fraction (`PlayerSheetMorph`). Collapsed, the card is the
/// album-tinted glass mini player; while it expands the glass fades out over the first quarter and the album's
/// `primaryContainer` fades in — the full player's background, as in Android's glass mode.
struct PlayerSheetHost: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    /// Locks a drag to one axis on its first movement (vertical moves the sheet).
    @State private var dragAxis: Axis?
    @State private var edgeDragActive = false

    var body: some View {
        let sheet = env.playerSheet
        GeometryReader { proxy in
            // The reader respects the safe area, so it knows the device insets; the card is laid out over the
            // whole screen and shifted back by them.
            let insets = proxy.safeAreaInsets
            let global = proxy.frame(in: .global)
            let screenOrigin = CGPoint(x: global.minX - insets.leading, y: global.minY - insets.top)
            let screen = CGRect(x: 0, y: 0, width: proxy.size.width + insets.leading + insets.trailing,
                                height: proxy.size.height + insets.top + insets.bottom)
            if let song = playback.current,
               let slot = sheet.collapsedFrame ?? (sheet.isExpanded ? fallbackSlot(in: screen, insets: insets) : nil) {
                let collapsed = slot.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
                card(song: song, screen: screen, safeArea: insets, collapsedMinX: collapsed.minX)
                    .modifier(PlayerSheetMorph(progress: sheet.expansion, collapsed: collapsed, screen: screen,
                                               collapsedBottomRadius: sheet.collapsedBottomRadius,
                                               glassTint: theme.primaryContainer.opacity(GlassTint.container),
                                               fill: theme.primaryContainer,
                                               overshootScaleY: sheet.overshootScaleY))
                    .simultaneousGesture(sheetDrag(distance: max(collapsed.minY, 1)))
                    .overlay(alignment: .leading) {
                        if sheet.isExpanded { edgeBackStrip(width: screen.width) }
                    }
                    .modifier(KeyboardStepAside(isHidden: sheet.hiddenForKeyboard && !sheet.isExpanded
                                                    && !sheet.isDragging))
                    .offset(x: -insets.leading, y: -insets.top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .topLeading) { SheetProbeLabel() }
        .animation(PixlMotion.bars, value: playback.hasItem)
        .onAppear { consumeCoverRequest() }
        .onChange(of: router.cover) { _, _ in consumeCoverRequest() }
        .onChange(of: playback.hasItem) { _, hasItem in
            if !hasItem {
                sheet.collapse(animated: false)
                sheet.resetFullPlayer()
            }
        }
    }

    /// The mini and full layers, both laid out once at their own sizes; only the morph modifier moves.
    private func card(song: Song, screen: CGRect, safeArea: EdgeInsets, collapsedMinX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            FullPlayerLayer(screenSize: screen.size, safeArea: safeArea, collapsedMinX: collapsedMinX)
            MiniPlayerLayer(song: song)
        }
    }

    /// Before the shell has reported the slot (launch straight into the expanded player), collapse to where the
    /// mini player sits above the bottom bar.
    private func fallbackSlot(in screen: CGRect, insets: EdgeInsets) -> CGRect {
        let inset = Tokens.Shell.horizontalInset
        let height = Tokens.Shell.miniPlayerHeight
        let y = screen.maxY - insets.bottom - Tokens.Shell.navBarHeight - Tokens.Shell.miniPlayerSpacing - height
        return CGRect(x: inset, y: y, width: screen.width - inset * 2, height: height)
    }

    /// `AppCover.nowPlaying` (the mini player's tap in older code, deep links, `-screen nowPlaying`) means "expand":
    /// the sheet takes the request and clears the cover so it never opens as a separate full-screen cover.
    private func consumeCoverRequest() {
        guard router.cover == .nowPlaying else { return }
        router.dismissCover()
        guard playback.hasItem else { return }
        env.playerSheet.expand(animated: env.launch.isUITest ? false : true)
    }

    // MARK: Gestures

    /// Vertical drags move the sheet: up from the mini player expands, down on the full player collapses. Upward
    /// drags on the expanded player open the queue on release (Android's queue drag).
    private func sheetDrag(distance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let sheet = env.playerSheet
                if dragAxis == nil {
                    dragAxis = abs(value.translation.height) >= abs(value.translation.width) ? .vertical : .horizontal
                    if dragAxis == .vertical, !sheet.isScrubbing, !edgeDragActive,
                       !(sheet.isExpanded && value.translation.height < 0) {
                        sheet.beginDrag()
                    }
                }
                guard sheet.isDragging else { return }
                sheet.drag(translationY: value.translation.height, distance: distance)
            }
            .onEnded { value in
                let sheet = env.playerSheet
                defer { dragAxis = nil }
                if sheet.isDragging {
                    sheet.endDrag(velocityY: value.velocity.height, distance: distance)
                } else if dragAxis == .vertical, sheet.isExpanded, !sheet.isScrubbing,
                          value.translation.height < -8, value.velocity.height < -190 || value.translation.height < -60 {
                    router.present(AppSheet.queue)
                }
            }
    }

    /// A strip along the leading edge: swiping in collapses the expanded player, following the finger.
    private func edgeBackStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        let sheet = env.playerSheet
                        if !edgeDragActive {
                            edgeDragActive = true
                            sheet.beginDrag()
                        }
                        let progress = min(max(value.translation.width / (width * 0.6), 0), 1)
                        sheet.drag(translationY: progress * 0.35, distance: 1)
                    }
                    .onEnded { value in
                        let sheet = env.playerSheet
                        edgeDragActive = false
                        sheet.isDragging = false
                        if value.translation.width > 80 || value.velocity.width > 400 {
                            sheet.collapse()
                        } else {
                            sheet.expand()
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

/// The card's geometry and background for an expansion fraction (Android `SheetVisualState`): frame, corners,
/// glass and fill. `Animatable`, so a spring interpolates `progress` and everything derived from it follows Android's
/// curves frame by frame. The layers' fades are their own `Animatable` modifiers on the same spring (this modifier
/// no longer writes the progress into the environment every frame, which made every environment reader in the
/// full player check its value 120 times a second).
struct PlayerSheetMorph: ViewModifier, Animatable {
    nonisolated var animatableData: CGFloat
    let collapsed: CGRect
    let screen: CGRect
    let collapsedBottomRadius: CGFloat
    let glassTint: Color
    let fill: Color
    let overshootScaleY: CGFloat

    init(progress: CGFloat, collapsed: CGRect, screen: CGRect, collapsedBottomRadius: CGFloat, glassTint: Color,
         fill: Color, overshootScaleY: CGFloat) {
        animatableData = progress
        self.collapsed = collapsed
        self.screen = screen
        self.collapsedBottomRadius = collapsedBottomRadius
        self.glassTint = glassTint
        self.fill = fill
        self.overshootScaleY = overshootScaleY
    }

    func body(content: Content) -> some View {
        let f = min(max(animatableData, 0), 1)
        let x = lerp(collapsed.minX, screen.minX, f)
        let y = lerp(collapsed.minY, screen.minY, f)
        let width = lerp(collapsed.width, screen.width, f)
        let height = lerp(collapsed.height, screen.height, f)
        let top = lerp(Tokens.Shell.navBarCornerRadius, 0, f)
        let bottom = lerp(collapsedBottomRadius, 0, f)
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        let glassAlpha = min(max(1 - f * 4, 0), 1)
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(shape)
            .background {
                ZStack {
                    if glassAlpha > 0 {
                        Color.clear
                            .pixlGlass(in: shape, tint: glassTint, interactive: f < 0.01)
                            .opacity(glassAlpha)
                    }
                    // Always mounted (transparent at rest): no view inserted when an expand starts.
                    shape.fill(fill).opacity(min(f * 4, 1))
                }
            }
            .contentShape(shape)
            .scaleEffect(x: 1, y: overshootScaleY, anchor: .bottom)
            .offset(x: x, y: y)
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// While the keyboard is up the collapsed card steps aside with the tab bar: what the shell's slot declares for a
/// 64 pt view (`.move(edge: .bottom).combined(with: .opacity)`), driven by the shell's `PixlMotion.bars` transaction.
private struct KeyboardStepAside: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isHidden ? Tokens.Shell.miniPlayerHeight : 0)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
    }
}

/// The mini player inside the card (Android `MiniPlayerContentInternal`): drawn without its own glass (the card is
/// the glass), fading out over the first half of the expansion and only tappable while collapsed.
private struct MiniPlayerLayer: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        MiniPlayerBar(song: song, isPlaying: playback.isPlaying, isPreparing: playback.isPreparing,
                      drawsGlass: false,
                      onOpen: { env.playerSheet.expand() },
                      onPrevious: { playback.skipToPrevious() },
                      onPlayPause: { playback.togglePlayPause() },
                      onNext: { playback.skipToNext() })
            .modifier(MiniLayerFade())
            // Build the full player while nothing moves, a second after the mini player appears (not inside its own
            // appear animation): the first expand then only animates.
            .task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, !SheetProbe.noPrewarm else { return }
                env.playerSheet.prewarm()
            }
    }
}

private struct MiniLayerFade: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.modifier(MiniLayerFadeEffect(progress: env.playerSheet.expansion))
    }
}

private struct MiniLayerFadeEffect: ViewModifier, Animatable {
    nonisolated var animatableData: CGFloat

    init(progress: CGFloat) { animatableData = progress }

    func body(content: Content) -> some View {
        let metrics = PlayerSheetMetrics(progress: min(max(animatableData, 0), 1))
        let alpha = metrics.miniPlayerAlpha
        content
            .frame(height: Tokens.Shell.miniPlayerHeight)
            .opacity(alpha)
            .allowsHitTesting(metrics.progress < 0.5)
            .accessibilityHidden(alpha == 0)
    }
}

/// The full player inside the card, laid out at screen size and kept horizontally in place while the card grows
/// around it; it fades in from 25 % with Android's 24 pt slide (`FullPlayerVisualState`).
///
/// Built once (pre-warmed, or by the first expand or drag) and kept: rebuilding the whole player — carousel, seek
/// bar, controls, background, about nine glass shapes, measured widths — inside the first frames of every expand
/// cost frames. While collapsed it stays hidden exactly where it used to be removed (on the collapse's first frame,
/// without animation), out of hit testing and accessibility, its timelines paused.
private struct FullPlayerLayer: View {
    let screenSize: CGSize
    let safeArea: EdgeInsets
    let collapsedMinX: CGFloat

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sheet = env.playerSheet
        let isShown = sheet.isExpanded || sheet.isDragging || sheet.expansion > 0.001
        if sheet.hasBuiltFullPlayer || isShown {
            NowPlayingView(safeArea: safeArea, width: screenSize.width)
                .frame(width: screenSize.width, height: screenSize.height)
                .modifier(FullLayerPlacement(collapsedMinX: collapsedMinX))
                .animation(nil) { content in
                    // While hidden it also takes no room in the card's ZStack, as when it was removed: a screen-sized
                    // child widened the ZStack, and the mini player beside it was laid out at the screen's width
                    // (its trailing controls ran past the card). The zero frame anchors it top-leading, unchanged.
                    content
                        .opacity(isShown ? 1 : 0)
                        .frame(width: isShown ? nil : 0, height: isShown ? nil : 0, alignment: .topLeading)
                }
                .onAppear { sheet.fullPlayerDidAppear() }
        }
    }
}

private struct FullLayerPlacement: ViewModifier {
    let collapsedMinX: CGFloat

    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.modifier(FullLayerPlacementEffect(progress: env.playerSheet.expansion, collapsedMinX: collapsedMinX))
    }
}

/// `PlayerSheetMorph`'s geometry for the full layer: the card's leading edge moves from the slot's to 0.
private struct FullLayerPlacementEffect: ViewModifier, Animatable {
    nonisolated var animatableData: CGFloat
    let collapsedMinX: CGFloat

    init(progress: CGFloat, collapsedMinX: CGFloat) {
        animatableData = progress
        self.collapsedMinX = collapsedMinX
    }

    func body(content: Content) -> some View {
        let f = min(max(animatableData, 0), 1)
        let _ = SheetProbe.markFullEffect(animatableData)
        let metrics = PlayerSheetMetrics(progress: f, cardMinX: collapsedMinX + (0 - collapsedMinX) * f)
        let alpha = metrics.fullPlayerAlpha
        content
            .opacity(alpha)
            .offset(x: -metrics.cardMinX, y: 24 * (1 - alpha))
            .allowsHitTesting(metrics.progress > 0.5)
            .accessibilityHidden(metrics.progress < 0.5)
    }
}

/// Where the mini player sits in the shell (above the bottom bar): an empty 64 pt box that reports its frame and
/// bottom corners to the sheet, which draws the mini player there.
struct MiniPlayerSlot: View {
    let bottomCornerRadius: CGFloat

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Color.clear
            .frame(height: Tokens.Shell.miniPlayerHeight)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                withAnimation(PixlMotion.bars) {
                    env.playerSheet.updateSlot(frame: frame, bottomRadius: bottomCornerRadius)
                }
            }
            .onChange(of: bottomCornerRadius) { _, radius in
                withAnimation(PixlMotion.bars) {
                    env.playerSheet.updateSlot(frame: env.playerSheet.collapsedFrame ?? .zero, bottomRadius: radius)
                }
            }
            .onDisappear { env.playerSheet.removeSlot() }
            .accessibilityHidden(true)
    }
}
