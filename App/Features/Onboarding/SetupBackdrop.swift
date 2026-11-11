import SwiftUI

/// Whether the setup's endless motion (drifting mesh, bobbing chips, breathing logo) stays still: with Reduce Motion,
/// and in UI tests so the screenshots are steady and XCTest can reach idle.
enum SetupMotion {
    static func isStill(reduceMotion: Bool) -> Bool {
        reduceMotion || LaunchConfiguration.current.isUITest
    }
}

/// The setup's living background: a slowly drifting mesh of the theme's container colours, plus three soft glows that
/// swing to a new corner on every page. It is one cheap GPU layer: the mesh is the only thing redrawn, at 20 fps (the
/// drift is far too slow to show more), and the glows are gradients that only move when the page changes. With
/// Reduce Transparency it is a flat tint, with Reduce Motion a still mesh.
struct SetupBackdrop: View {
    let page: Int
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            theme.background
            if reduceTransparency {
                LinearGradient(colors: [theme.primaryContainer.opacity(0.4), .clear],
                               startPoint: .top, endPoint: .center)
            } else {
                SetupMesh(theme: theme)
                SetupGlows(page: page, theme: theme)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct SetupMesh: View {
    let theme: ThemeColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = SetupMotion.isStill(reduceMotion: reduceMotion)
        let colors = Self.colors(theme)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { context in
            let time = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            MeshGradient(width: 3, height: 3, points: Self.points(t: time), colors: colors)
        }
        .longRunning("setup.backdrop (20 fps timeline)", active: !still)
    }

    private static func colors(_ theme: ThemeColors) -> [Color] {
        let bg = theme.background
        let primary = theme.primaryContainer
        let tertiary = theme.tertiaryContainer
        let secondary = theme.secondaryContainer
        return [bg, primary.opacity(0.55), tertiary.opacity(0.35),
                secondary.opacity(0.4), bg, primary.opacity(0.5),
                bg, tertiary.opacity(0.4), primary.opacity(0.3)]
    }

    /// A 3×3 mesh: the corners stay put, the edge midpoints slide along their edges and the centre wanders.
    private static func points(t: Double) -> [SIMD2<Float>] {
        func f(_ value: Double) -> Float { Float(value) }
        return [
            [0, 0], [f(0.5 + 0.14 * sin(t * 0.42)), 0], [1, 0],
            [0, f(0.5 + 0.14 * sin(t * 0.36 + 1.3))],
            [f(0.5 + 0.1 * sin(t * 0.5)), f(0.5 + 0.1 * cos(t * 0.44))],
            [1, f(0.5 + 0.14 * cos(t * 0.4 + 0.4))],
            [0, 1], [f(0.5 + 0.14 * cos(t * 0.47 + 2.1)), 1], [1, 1],
        ]
    }
}

/// Three radial glows (primary, tertiary, secondary) that rotate around the screen one slot per page.
private struct SetupGlows: View {
    let page: Int
    let theme: ThemeColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slots: [CGPoint] = [CGPoint(x: 0.12, y: 0.08), CGPoint(x: 0.92, y: 0.38), CGPoint(x: 0.28, y: 0.96)]

    var body: some View {
        GeometryReader { proxy in
            let radius = max(proxy.size.width, 320) * 0.62
            ZStack {
                glow(theme.primary, slot: 0, in: proxy.size, radius: radius)
                glow(theme.tertiary, slot: 1, in: proxy.size, radius: radius)
                glow(theme.secondary, slot: 2, in: proxy.size, radius: radius)
            }
            .animation(reduceMotion ? nil : .spring(response: 1.2, dampingFraction: 0.9), value: page)
        }
    }

    private func glow(_ color: Color, slot: Int, in size: CGSize, radius: CGFloat) -> some View {
        let point = Self.slots[(slot + page) % Self.slots.count]
        return Circle()
            .fill(RadialGradient(colors: [color.opacity(0.26), color.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .position(x: size.width * point.x, y: size.height * point.y)
    }
}
