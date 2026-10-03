import SwiftUI
import UIKit

/// The easter egg (Android `EasterEggScreen` + `BrickBreakerOverlay`), opened by long-pressing the version on
/// About: a "thank you" toast, then Brick Breaker — the header (star, app name, HIGH capsule, close circle), the
/// stats card (score, level capsule, lives), the 24 pt game area and, when nothing plays, "Play Random Music".
/// Surfaces are glass; the game itself is drawn with Canvas, driven by `TimelineView(.animation)` only while the
/// ball flies or particles fall (paused otherwise).
struct EasterEggView: View {
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var game = BrickBreakerGame()
    @State private var toast: String?
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            stats
            gameArea
            bottom
        }
        .background(theme.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(SettingsBackSwipeEnabler().frame(width: 0, height: 0))
        .settingsToast($toast)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.97)
        .offset(y: visible ? 0 : 60)
        .onAppear {
            game.hapticsEnabled = settings.behavior.hapticsEnabled
            withAnimation(.easeOut(duration: 0.36)) { visible = true }
            toast = L10n.easterEggThankYou
        }
    }

    /// Android header: `surfaceContainer` under the status bar.
    private var header: some View {
        HStack {
            Image(systemName: "star.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.primary)
            Spacer().frame(width: 8)
            Text(L10n.aboutAppName).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                // The ready element sits on one view: an identifier on the root would override the children's.
                .accessibilityIdentifier("screen.easterEgg")
            Spacer()
            Text(L10n.brickHigh(game.highScore))
                .pixlFont(.labelMedium, weight: .semibold)
                .foregroundStyle(theme.onTertiaryContainer)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.tertiaryContainer, in: Capsule())
            Spacer().frame(width: 8)
            GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(L10n.brickCdClose), size: 32,
                              iconSize: 15, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                              foreground: theme.onSurfaceVariant) { dismiss() }
                .accessibilityIdentifier("brick.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.surfaceContainer.ignoresSafeArea(edges: .top))
    }

    /// Android stats card: `secondaryContainer`, 16 pt corners (glass), score / level capsule / lives.
    private var stats: some View {
        HStack {
            Spacer()
            stat(L10n.brickStatScore, "\(game.score)", lives: false)
            Spacer()
            Text(L10n.brickStatLvl(game.level))
                .pixlFont(.labelLarge, weight: .black)
                .foregroundStyle(theme.onPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(theme.primary, in: Capsule())
            Spacer()
            stat(L10n.brickStatLives, "\(game.lives)", lives: true)
            Spacer()
        }
        .padding(.vertical, 12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.secondaryContainer.opacity(GlassTint.container))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: String, lives: Bool) -> some View {
        VStack(spacing: 0) {
            Text(label).pixlFont(.labelSmall, weight: .bold).foregroundStyle(theme.onSecondaryContainer.opacity(0.6))
            HStack(spacing: 4) {
                if lives {
                    Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(theme.error)
                }
                Text(value).pixlFont(.titleLarge, weight: .bold).foregroundStyle(theme.onSecondaryContainer)
                    .monospacedDigit()
            }
        }
    }

    private var gameArea: some View {
        let colors = BrickBreakerGame.Palette(primary: theme.primary, onSurface: theme.onSurface,
                                              primaryContainer: theme.primaryContainer, secondary: theme.secondary,
                                              tertiary: theme.tertiary, outlineVariant: theme.outlineVariant)
        return ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: !game.needsFrames)) { timeline in
                Canvas { context, size in
                    game.advance(to: timeline.date, area: size, palette: colors)
                    game.draw(in: &context)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { game.resize($0, palette: colors) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { game.drag(to: $0.location.x, start: $0.startLocation.x, palette: colors) }
                    .onEnded { value in
                        game.endDrag()
                        if abs(value.translation.width) < 4 && abs(value.translation.height) < 4 { game.tap() }
                    }
            )
            .accessibilityLabel(L10n.brickTitle)
            .accessibilityHint(L10n.brickDragPaddle)

            if !game.hasStarted {
                preLaunch
            } else if game.isGameOver || game.hasWon {
                endOverlay(colors)
            } else if !game.ballLaunched {
                Text(L10n.brickTapRelaunch)
                    .pixlFont(.labelLarge, weight: .bold)
                    .tracking(1.2)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHighest.opacity(GlassTint.bar))
                    .padding(.bottom, 100)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    /// Android `PreLaunchMenu`: a 28 pt card with the star, title, high score capsule, Play and the hint.
    private var preLaunch: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(theme.primary)
            Text(L10n.brickTitle).pixlFont(.titleLarge, weight: .bold).foregroundStyle(theme.onSurface)
            Text(L10n.brickHighScore(game.highScore))
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.onTertiaryContainer)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.tertiaryContainer, in: Capsule())
            Button {
                game.play()
            } label: {
                Text(L10n.brickPlay)
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .background(theme.primary, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            .accessibilityIdentifier("brick.play")
            Text(L10n.brickDragPaddle).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.bar))
        .padding(.horizontal, 24)
    }

    private func endOverlay(_ colors: BrickBreakerGame.Palette) -> some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 0) {
                Image(systemName: game.hasWon ? "star.fill" : "arrow.clockwise")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 16)
                Text(game.hasWon ? L10n.brickLevelComplete : L10n.brickGameOver)
                    .pixlFont(.headlineLarge, weight: .black)
                    .foregroundStyle(.white)
                Spacer().frame(height: 8)
                Text(game.hasWon ? L10n.brickScoreLine(game.score) : L10n.brickTryAgain)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer().frame(height: 32)
                Button {
                    if game.hasWon { game.nextLevel(palette: colors) } else { game.reset(full: true, palette: colors) }
                } label: {
                    Text(game.hasWon ? L10n.brickNextLevel : L10n.brickRestart)
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onPrimaryContainer)
                        .padding(.horizontal, 24)
                        .frame(height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
                .accessibilityIdentifier("brick.next")
            }
        }
    }

    /// While a song plays the mini player takes this place (Android's `MiniPlayerHeight + 8` spacer); the route's
    /// safe area already ends above it (`BottomBarsClearance`).
    @ViewBuilder
    private var bottom: some View {
        if playback.current == nil {
            Button {
                let songs = library.songs.shuffled()
                if !songs.isEmpty { playback.play(songs, startIndex: 0) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shuffle").font(.system(size: 18, weight: .semibold))
                    Text(L10n.brickPlayRandom).pixlFont(.labelLarge, weight: .bold)
                }
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Shell.miniPlayerHeight)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                       tint: theme.primaryContainer.opacity(GlassTint.container), interactive: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityIdentifier("brick.playRandom")
        }
    }
}

// MARK: - Game (Android `BrickBreakerOverlay` state and physics)

/// The Brick Breaker model. Score, lives, level and the overlay flags are observable (they change rarely); the
/// per-frame state (ball, paddle, bricks, particles) is not, so frames only redraw the Canvas.
@Observable
final class BrickBreakerGame {
    nonisolated struct Palette: Equatable {
        var primary: Color
        var onSurface: Color
        var primaryContainer: Color
        var secondary: Color
        var tertiary: Color
        var outlineVariant: Color
    }

    nonisolated enum BrickType { case normal, hard, solid }

    nonisolated struct Brick {
        var rect: CGRect
        var hitsRemaining: Int
        var type: BrickType
        var color: Color
    }

    nonisolated struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var color: Color
        var radius: CGFloat
        var life: CGFloat = 1
    }

    // Android's constants are in px; the reference phone draws ~2.75 px per dp (= pt), so px values are divided.
    nonisolated private static let px: CGFloat = 1 / 2.75
    nonisolated private static let baseBallVelocity: CGFloat = 800 * px
    nonisolated private static let fixedStep: CGFloat = 1 / 180
    nonisolated private static let maxStepsPerFrame = 8
    nonisolated private static let paddleHeight: CGFloat = 16
    nonisolated private static let paddleBottomInset: CGFloat = 32
    nonisolated private static let ballRadius: CGFloat = 10
    nonisolated static let highScoreKey = "brick_breaker_high_score"

    private(set) var level = 1
    private(set) var lives = 3
    private(set) var score = 0
    private(set) var highScore = UserDefaults.standard.integer(forKey: BrickBreakerGame.highScoreKey)
    private(set) var hasStarted = false
    private(set) var hasWon = false
    private(set) var isGameOver = false
    private(set) var ballLaunched = false
    /// True while particles are still falling (keeps frames running after the ball stops).
    private var particlesActive = false

    @ObservationIgnored var hapticsEnabled = true
    @ObservationIgnored private var area: CGSize = .zero
    @ObservationIgnored private var paddleX: CGFloat = 0
    @ObservationIgnored private var paddleWidth: CGFloat = 0
    @ObservationIgnored private var speedMultiplier: CGFloat = 1
    @ObservationIgnored private var ball = CGPoint.zero
    @ObservationIgnored private var velocity = CGVector(dx: 1, dy: -1)
    @ObservationIgnored private var bricks: [Brick] = []
    @ObservationIgnored private var particles: [Particle] = []
    @ObservationIgnored private var accumulator: CGFloat = 0
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var dragLastX: CGFloat?
    @ObservationIgnored private var palette: Palette?
    @ObservationIgnored private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let rigidHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    var needsFrames: Bool { ballLaunched || particlesActive }

    // MARK: Setup

    func resize(_ size: CGSize, palette: Palette) {
        guard size.width > 0, size.height > 0 else { return }
        let first = area == .zero
        area = size
        self.palette = palette
        if first {
            reset(full: true, palette: palette)
        } else {
            paddleWidth = size.width * max(0.25 - CGFloat(level) * 0.02, 0.10)
            paddleX = min(max(paddleX, 0), max(size.width - paddleWidth, 0))
            if !ballLaunched && !isGameOver && !hasWon { attachBall() }
        }
    }

    func play() {
        guard let palette else { return }
        reset(full: true, palette: palette)
        hasStarted = true
        launch()
    }

    func reset(full: Bool, palette: Palette) {
        isGameOver = false
        hasWon = false
        ballLaunched = false
        accumulator = 0
        particles.removeAll()
        particlesActive = false
        if full {
            score = 0
            lives = 3
            level = 1
            hasStarted = false
        }
        generateLevel(level, palette: palette)
        centerPaddle()
        attachBall()
    }

    func nextLevel(palette: Palette) {
        level += 1
        ballLaunched = false
        hasWon = false
        accumulator = 0
        generateLevel(level, palette: palette)
        centerPaddle()
        attachBall()
    }

    private func generateLevel(_ lvl: Int, palette: Palette) {
        guard area != .zero else { return }
        bricks.removeAll()
        particles.removeAll()
        speedMultiplier = 1 + CGFloat(lvl - 1) * 0.1
        paddleWidth = area.width * max(0.25 - CGFloat(lvl) * 0.02, 0.10)
        let padding: CGFloat = 8
        let top: CGFloat = 20
        let rows = min(5 + lvl, 10)
        let cols = 8
        let brickHeight: CGFloat = 24
        let brickWidth = max((area.width - padding * CGFloat(cols + 1)) / CGFloat(cols), 10 * Self.px)
        for row in 0..<rows {
            for col in 0..<(cols / 2) {
                let skip = Double.random(in: 0..<1) < min(0.1 * (Double(lvl) * 0.5), 0.3)
                let hard = Double.random(in: 0..<1) < min(0.1 * Double(lvl), 0.4)
                let solid = lvl > 2 && Double.random(in: 0..<1) < 0.05 && row > 1
                guard !skip else { continue }
                let type: BrickType = solid ? .solid : hard ? .hard : .normal
                let hits = type == .hard ? 2 : 1
                let color = switch type {
                case .solid: palette.outlineVariant
                case .hard: palette.secondary
                case .normal: palette.primaryContainer
                }
                let y = top + CGFloat(row) * (brickHeight + padding)
                for c in [col, cols - 1 - col] {
                    let x = padding + CGFloat(c) * (brickWidth + padding)
                    bricks.append(Brick(rect: CGRect(x: x, y: y, width: brickWidth, height: brickHeight),
                                        hitsRemaining: hits, type: type, color: color))
                }
            }
        }
    }

    private func centerPaddle() {
        guard area != .zero else { return }
        paddleX = max((area.width - paddleWidth) / 2, 0)
    }

    private func attachBall() {
        guard area != .zero else { return }
        let paddleTop = area.height - Self.paddleBottomInset - Self.paddleHeight
        ball = CGPoint(x: paddleX + paddleWidth / 2, y: paddleTop - Self.ballRadius - 4 * Self.px)
        let speed = Self.baseBallVelocity * speedMultiplier
        velocity = CGVector(dx: CGFloat.random(in: -0.5..<0.5) * speed, dy: -speed)
    }

    private func launch() {
        lastFrame = nil
        ballLaunched = true
    }

    // MARK: Input

    func drag(to x: CGFloat, start: CGFloat, palette: Palette) {
        guard hasStarted else { return }
        if dragLastX == nil {
            dragLastX = start
            if !ballLaunched && !isGameOver && !hasWon { launch() }
        }
        let delta = x - (dragLastX ?? x)
        dragLastX = x
        guard area != .zero else { return }
        paddleX = min(max(paddleX + delta, 0), max(area.width - paddleWidth, 0))
        if !ballLaunched { attachBall() }
    }

    func endDrag() { dragLastX = nil }

    func tap() {
        guard hasStarted, !ballLaunched, !isGameOver, !hasWon else { return }
        launch()
    }

    // MARK: Frame

    func advance(to date: Date, area size: CGSize, palette: Palette) {
        self.palette = palette
        guard let last = lastFrame else {
            lastFrame = date
            return
        }
        lastFrame = date
        let dt = min(max(CGFloat(date.timeIntervalSince(last)), 0), 0.05)
        guard area != .zero else { return }
        stepParticles(dt)
        guard ballLaunched else {
            accumulator = 0
            return
        }
        accumulator = min(accumulator + dt, 0.2)
        var steps = 0
        while accumulator >= Self.fixedStep && steps < Self.maxStepsPerFrame {
            accumulator -= Self.fixedStep
            steps += 1
            if !physicsStep(palette: palette) { break }
        }
    }

    private func stepParticles(_ dt: CGFloat) {
        guard !particles.isEmpty else {
            if particlesActive { particlesActive = false }
            return
        }
        var alive: [Particle] = []
        alive.reserveCapacity(particles.count)
        for var p in particles where p.life > 0 {
            p.life -= dt * 1.5
            p.velocity.dy += 800 * Self.px * dt
            p.position.x += p.velocity.dx * dt
            p.position.y += p.velocity.dy * dt
            alive.append(p)
        }
        particles = alive
    }

    /// One fixed physics step; false when the ball was lost or the level cleared (stop stepping this frame).
    private func physicsStep(palette: Palette) -> Bool {
        var position = ball
        var v = velocity
        let r = Self.ballRadius
        let stepDistance = hypot(v.dx, v.dy) * Self.fixedStep
        let subSteps = min(max(1, Int((stepDistance / max(r * 0.45, Self.px)).rounded(.up))), 8)
        let subDelta = Self.fixedStep / CGFloat(subSteps)
        var brickResolved = false
        for _ in 0..<subSteps {
            let previous = position
            var candidate = CGPoint(x: previous.x + v.dx * subDelta, y: previous.y + v.dy * subDelta)
            if candidate.x - r <= 0 { candidate.x = r; v.dx = abs(v.dx) }
            if candidate.x + r >= area.width { candidate.x = area.width - r; v.dx = -abs(v.dx) }
            if candidate.y - r <= 0 { candidate.y = r; v.dy = abs(v.dy) }

            let paddleTop = area.height - Self.paddleBottomInset - Self.paddleHeight
            let paddle = CGRect(x: paddleX, y: paddleTop, width: paddleWidth, height: Self.paddleHeight)
            if v.dy > 0, Self.circleIntersects(candidate, r, paddle) {
                let hit = min(max((candidate.x - paddle.midX) / (paddleWidth / 2), -1), 1)
                let current = max(hypot(v.dx, v.dy), Self.baseBallVelocity * 0.85)
                let speed = min(current * 1.015, Self.baseBallVelocity * 3)
                let vx = speed * hit * 0.82
                let vy = max((max(0, speed * speed - vx * vx)).squareRoot(), speed * 0.35)
                v = CGVector(dx: vx, dy: -vy)
                candidate.y = paddle.minY - r - Self.px
                haptic(lightHaptic)
            }

            if !brickResolved, let index = bricks.firstIndex(where: {
                ($0.hitsRemaining > 0 || $0.type == .solid) && Self.circleIntersects(candidate, r, $0.rect)
            }) {
                let brick = bricks[index]
                brickResolved = true
                let normal = Self.collisionNormal(previous: previous, current: candidate, rect: brick.rect)
                v = Self.enforceMinimumVerticalSpeed(Self.reflect(v, normal))
                candidate = Self.resolve(candidate, r, brick.rect, normal)
                haptic(rigidHaptic)
                if brick.type != .solid {
                    let remaining = brick.hitsRemaining - 1
                    spawnParticles(brick.rect, brick.color, count: 8)
                    if remaining > 0 {
                        bricks[index].hitsRemaining = remaining
                        if remaining == 1 { bricks[index].color = palette.tertiary }
                    } else {
                        bricks[index].hitsRemaining = remaining
                        score += brick.type == .hard ? 100 : 50
                        updateHighScore()
                        haptic(heavyHaptic)
                    }
                    v = Self.enforceMinimumVerticalSpeed(CGVector(dx: v.dx * 1.01, dy: v.dy * 1.01))
                    if !bricks.contains(where: { $0.type != .solid && $0.hitsRemaining > 0 }) {
                        hasWon = true
                        ballLaunched = false
                        updateHighScore()
                        ball = candidate
                        velocity = v
                        return false
                    }
                } else {
                    spawnParticles(brick.rect, .gray, count: 3)
                }
            }

            if candidate.y - r > area.height {
                lives -= 1
                ballLaunched = false
                accumulator = 0
                if lives <= 0 {
                    isGameOver = true
                    updateHighScore()
                }
                attachBall()
                return false
            }
            position = candidate
        }
        ball = position
        velocity = v
        return true
    }

    private func spawnParticles(_ rect: CGRect, _ color: Color, count: Int) {
        for _ in 0..<count {
            let angle = Double.random(in: 0..<360) * .pi / 180
            let speed = CGFloat.random(in: 100..<400) * Self.px
            particles.append(Particle(
                position: CGPoint(x: rect.midX + CGFloat.random(in: 0..<1) * rect.width * 0.5 - rect.width * 0.25,
                                  y: rect.midY + CGFloat.random(in: 0..<1) * rect.height * 0.5 - rect.height * 0.25),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                color: color, radius: CGFloat.random(in: 4..<12) * Self.px))
        }
        if !particlesActive { particlesActive = true }
    }

    private func updateHighScore() {
        guard score > highScore else { return }
        highScore = score
        UserDefaults.standard.set(score, forKey: Self.highScoreKey)
    }

    private func haptic(_ generator: UIImpactFeedbackGenerator) {
        if hapticsEnabled { generator.impactOccurred() }
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext) {
        guard let palette else { return }
        for brick in bricks where brick.hitsRemaining > 0 || brick.type == .solid {
            context.fill(Path(roundedRect: brick.rect, cornerRadius: 6), with: .color(brick.color))
            if brick.type == .solid {
                context.fill(Path(ellipseIn: CGRect(x: brick.rect.midX - 4, y: brick.rect.midY - 4, width: 8, height: 8)),
                             with: .color(.black.opacity(0.2)))
            }
        }
        for p in particles where p.life > 0 {
            let radius = p.radius * p.life
            context.fill(Path(ellipseIn: CGRect(x: p.position.x - radius, y: p.position.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(p.color.opacity(Double(p.life))))
        }
        let paddleTop = area.height - Self.paddleBottomInset - Self.paddleHeight
        let paddle = CGRect(x: paddleX, y: paddleTop, width: paddleWidth, height: Self.paddleHeight)
        context.fill(Path(roundedRect: paddle, cornerRadius: Self.paddleHeight / 2), with: .color(palette.primary))
        let r = Self.ballRadius
        context.fill(Path(ellipseIn: CGRect(x: ball.x - r, y: ball.y - r, width: r * 2, height: r * 2)),
                     with: .color(palette.onSurface))
    }

    // MARK: Geometry (Android helpers)

    nonisolated private static func circleIntersects(_ c: CGPoint, _ r: CGFloat, _ rect: CGRect) -> Bool {
        let dx = c.x - min(max(c.x, rect.minX), rect.maxX)
        let dy = c.y - min(max(c.y, rect.minY), rect.maxY)
        return dx * dx + dy * dy <= r * r
    }

    nonisolated private static func normalized(_ v: CGVector) -> CGVector? {
        let length = hypot(v.dx, v.dy)
        guard length > 0.0001 else { return nil }
        return CGVector(dx: v.dx / length, dy: v.dy / length)
    }

    nonisolated private static func reflect(_ v: CGVector, _ normal: CGVector) -> CGVector {
        guard let n = normalized(normal) else { return v }
        let dot = v.dx * n.dx + v.dy * n.dy
        guard dot < 0 else { return v }
        return CGVector(dx: v.dx - n.dx * 2 * dot, dy: v.dy - n.dy * 2 * dot)
    }

    nonisolated private static func collisionNormal(previous: CGPoint, current: CGPoint, rect: CGRect) -> CGVector {
        let closestX = min(max(current.x, rect.minX), rect.maxX)
        let closestY = min(max(current.y, rect.minY), rect.maxY)
        if let outside = normalized(CGVector(dx: current.x - closestX, dy: current.y - closestY)) { return outside }
        let left = abs(current.x - rect.minX)
        let right = abs(rect.maxX - current.x)
        let top = abs(current.y - rect.minY)
        let bottom = abs(rect.maxY - current.y)
        let minimum = min(min(left, right), min(top, bottom))
        let axis: CGVector = minimum == left ? CGVector(dx: -1, dy: 0)
            : minimum == right ? CGVector(dx: 1, dy: 0)
            : minimum == top ? CGVector(dx: 0, dy: -1) : CGVector(dx: 0, dy: 1)
        let toCurrent = CGVector(dx: current.x - previous.x, dy: current.y - previous.y)
        return toCurrent.dx * axis.dx + toCurrent.dy * axis.dy < 0 ? axis : CGVector(dx: -axis.dx, dy: -axis.dy)
    }

    nonisolated private static func resolve(_ center: CGPoint, _ r: CGFloat, _ rect: CGRect,
                                            _ normal: CGVector) -> CGPoint {
        guard let n = normalized(normal) else { return center }
        let closest = CGPoint(x: min(max(center.x, rect.minX), rect.maxX), y: min(max(center.y, rect.minY), rect.maxY))
        let distance = hypot(center.x - closest.x, center.y - closest.y)
        let push: CGFloat
        if distance > 0.0001 {
            let out = r - distance
            guard out > 0 else { return center }
            push = out + 0.5 * px
        } else {
            push = r + 0.5 * px
        }
        return CGPoint(x: center.x + n.dx * push, y: center.y + n.dy * push)
    }

    nonisolated private static func enforceMinimumVerticalSpeed(_ v: CGVector, ratio: CGFloat = 0.22) -> CGVector {
        let speed = hypot(v.dx, v.dy)
        guard speed > 0 else { return v }
        let minVy = speed * ratio
        let signY: CGFloat = v.dy == 0 ? -1 : (v.dy < 0 ? -1 : 1)
        let vy = abs(v.dy) < minVy ? signY * minVy : v.dy
        let signX: CGFloat = v.dx == 0 ? 1 : (v.dx < 0 ? -1 : 1)
        return CGVector(dx: signX * max(0, speed * speed - vy * vy).squareRoot(), dy: vy)
    }
}
