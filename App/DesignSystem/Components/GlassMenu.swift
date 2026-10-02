import SwiftUI

// Liquid menus that pop out of the button that opens them. Hoa, 2026-10-02: "add the exploding liquid menus that
// like pop out from its like original position in a floating jelly-like menu/panel".
//
// A menu's glass starts as the button: same frame, same corner radius; the button itself hides. A bouncy spring
// then stretches it into a floating panel next to the button. The spring overshoots, so the panel swells slightly
// past its size and settles back, like jelly. The panel's content fades in once the glass has grown. Tapping
// outside, choosing an item or VoiceOver's escape shrinks the glass back into the button.
//
// Usage:
// - Mark the button with `.glassMenuAnchor("id", cornerRadius:)`.
// - In its action call `menus.present(from: "id") { … }` on the `GlassMenuPresenter` from the environment.
// - Content is any view: `GlassMenuItem` rows for action menus, or PixlAudio's own panels (sort options, playlist
//   options), which close themselves through `\.glassMenuDismiss`.
//
// Every presentation context has its own presenter and host, because a panel must float above the sheet it was
// opened from: the root shell (`RootView`) and every sheet (`pixlSheet`) install one with `.glassMenuHost()`.

/// Motion of the glass menus.
nonisolated enum GlassMenuMotion {
    /// Opening: under-damped, so the glass overshoots its size and settles (the jelly).
    static let open = Animation.spring(response: 0.46, dampingFraction: 0.64)
    /// Closing: quick and calm back into the button.
    static let close = Animation.spring(response: 0.3, dampingFraction: 0.92)
    /// How long the close spring takes to look finished before the button reappears.
    static let closeDuration: Duration = .milliseconds(320)
}

/// Owns the open menu of one presentation context (the shell, or one sheet) and the frames of its anchors.
@Observable
final class GlassMenuPresenter {
    struct Anchor: Equatable {
        var frame: CGRect
        var cornerRadius: CGFloat
    }

    struct Presentation: Identifiable {
        let id = UUID()
        let anchorID: String
        let anchor: Anchor
        let width: CGFloat
        let tint: Color?
        let content: AnyView
        let onDismiss: (() -> Void)?
    }

    /// Anchor frames in global coordinates. Not observed: they change while scrolling, and only `present` reads them.
    @ObservationIgnored private var anchors: [String: Anchor] = [:]
    private(set) var presentation: Presentation?
    /// 0 = the glass has the button's shape, 1 = the open panel. Springs move it; the host interpolates.
    private(set) var progress: CGFloat = 0
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    /// The anchor whose button is currently replaced by its menu (hidden until the menu has closed).
    var activeAnchorID: String? { presentation?.anchorID }

    func register(_ id: String, frame: CGRect, cornerRadius: CGFloat) {
        anchors[id] = Anchor(frame: frame, cornerRadius: cornerRadius)
    }

    func unregister(_ id: String) {
        anchors[id] = nil
        if presentation?.anchorID == id { finishClose() }
    }

    /// Opens a menu out of the anchor `anchorID`. `width` is the panel's width; `tint` tints its glass.
    func present<Content: View>(from anchorID: String, width: CGFloat = 250, tint: Color? = nil,
                                onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        guard let anchor = anchors[anchorID] else { return }
        closeTask?.cancel()
        closeTask = nil
        progress = 0
        presentation = Presentation(anchorID: anchorID, anchor: anchor, width: width, tint: tint,
                                    content: AnyView(content()), onDismiss: onDismiss)
    }

    /// Called by the host once the panel's content has been measured: grow out of the button.
    func open() {
        withAnimation(GlassMenuMotion.open) { progress = 1 }
    }

    /// Shrinks the menu back into its button, then removes it and shows the button again.
    func dismiss() {
        guard presentation != nil, closeTask == nil else { return }
        withAnimation(GlassMenuMotion.close) { progress = 0 }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: GlassMenuMotion.closeDuration)
            guard !Task.isCancelled else { return }
            self?.finishClose()
        }
    }

    private func finishClose() {
        let callback = presentation?.onDismiss
        closeTask = nil
        presentation = nil
        progress = 0
        callback?()
    }
}

extension EnvironmentValues {
    /// Closes the glass menu the view is shown in; nil outside a glass menu. Panels shared with sheets call this
    /// when set and `dismiss` otherwise.
    @Entry var glassMenuDismiss: (() -> Void)? = nil
}

extension View {
    /// Gives this subtree its own glass-menu presenter and floats its menus above it. Applied by the root shell and
    /// by `pixlSheet` (so menus opened inside a sheet float above that sheet).
    func glassMenuHost() -> some View {
        modifier(GlassMenuHostModifier())
    }

    /// Marks a button as the origin of a glass menu: reports its frame, and hides it while its menu is open (the
    /// menu's glass takes its place). `cornerRadius` is the button's shape (half its height for circles/capsules).
    func glassMenuAnchor(_ id: String, cornerRadius: CGFloat) -> some View {
        modifier(GlassMenuAnchorModifier(id: id, cornerRadius: cornerRadius))
    }
}

private struct GlassMenuHostModifier: ViewModifier {
    @State private var presenter = GlassMenuPresenter()

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .overlay { GlassMenuHost(presenter: presenter) }
    }
}

private struct GlassMenuAnchorModifier: ViewModifier {
    let id: String
    let cornerRadius: CGFloat

    @Environment(GlassMenuPresenter.self) private var presenter: GlassMenuPresenter?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                presenter?.register(id, frame: frame, cornerRadius: cornerRadius)
            }
            .opacity(presenter?.activeAnchorID == id ? 0 : 1)
            .onDisappear { presenter?.unregister(id) }
    }
}

// MARK: - Host

/// Covers its context; while a menu is open it catches taps outside the panel and draws the morphing panel.
private struct GlassMenuHost: View {
    let presenter: GlassMenuPresenter

    @State private var origin: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            if let presentation = presenter.presentation {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { presenter.dismiss() }
                        .accessibilityHidden(true)
                    GlassMenuPanel(presentation: presentation, presenter: presenter,
                                   bounds: CGRect(origin: .zero, size: proxy.size), origin: origin,
                                   safeArea: proxy.safeAreaInsets)
                        .id(presentation.id)
                }
            }
        }
        .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .global).origin
        } action: { newOrigin in
            origin = newOrigin
        }
        .ignoresSafeArea()
    }
}

/// One open menu: measures its content, places the panel next to the button, and morphs between the two.
private struct GlassMenuPanel: View {
    let presentation: GlassMenuPresenter.Presentation
    let presenter: GlassMenuPresenter
    let bounds: CGRect
    let origin: CGPoint
    let safeArea: EdgeInsets

    @State private var contentHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let margin: CGFloat = 12
    private static let panelRadius: CGFloat = 26

    var body: some View {
        let source = presentation.anchor.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        let width = min(presentation.width, bounds.width - Self.margin * 2)
        ZStack(alignment: .topLeading) {
            if let contentHeight {
                let layout = placement(source: source, width: width, contentHeight: contentHeight)
                panelContent(width: width)
                    .modifier(GlassMenuMorph(progress: presenter.progress, from: source,
                                             fromRadius: presentation.anchor.cornerRadius, to: layout.frame,
                                             toRadius: Self.panelRadius, contentAnchor: layout.anchor,
                                             tint: presentation.tint, jelly: !reduceMotion))
            } else {
                // Measure the content at the panel's width before growing (invisible, one pass).
                panelContent(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard contentHeight == nil, height > 0 else { return }
                        contentHeight = height
                        presenter.open()
                    }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    private func panelContent(width: CGFloat) -> some View {
        presentation.content
            .frame(width: width)
            .environment(\.glassMenuDismiss) { presenter.dismiss() }
            // A container, so the panel's own identifiers (rows, sort options) stay reachable.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { presenter.dismiss() }
            .accessibilityIdentifier("glassMenu")
    }

    /// Where the panel opens: from the button's edge nearest the screen edge, downwards when it fits (covering the
    /// button, which becomes the panel's corner), otherwise upwards; never past the safe area.
    private func placement(source: CGRect, width: CGFloat,
                           contentHeight: CGFloat) -> (frame: CGRect, anchor: UnitPoint) {
        let top = safeArea.top + Self.margin
        let bottom = bounds.height - safeArea.bottom - Self.margin
        let height = min(contentHeight, bottom - top)
        let opensDown = source.minY + height <= bottom || source.minY - top < bottom - source.maxY
        let alignsTrailing = source.midX > bounds.midX
        var x = alignsTrailing ? source.maxX - width : source.minX
        x = min(max(x, Self.margin), bounds.width - Self.margin - width)
        var y = opensDown ? source.minY : source.maxY - height
        y = min(max(y, top), bottom - height)
        let anchor: UnitPoint = switch (opensDown, alignsTrailing) {
        case (true, true): .topTrailing
        case (true, false): .topLeading
        case (false, true): .bottomTrailing
        case (false, false): .bottomLeading
        }
        return (CGRect(x: x, y: y, width: width, height: height), anchor)
    }
}

/// Interpolates the glass from the button's frame and corner radius to the panel's, every frame of the spring.
/// Above 1 (the spring's overshoot) the panel swells slightly past its size — the jelly.
private struct GlassMenuMorph: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGRect
    let fromRadius: CGFloat
    let to: CGRect
    let toRadius: CGFloat
    let contentAnchor: UnitPoint
    let tint: Color?
    let jelly: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let f = jelly ? progress : min(progress, 1)
        let width = max(1, lerp(from.width, to.width, f))
        let height = max(1, lerp(from.height, to.height, f))
        // The corner of the panel that sits on the button stays put; the rest grows away from it.
        let x = lerp(from.minX + (from.width - width) * contentAnchor.x, to.minX, f)
        let y = lerp(from.minY + (from.height - height) * contentAnchor.y, to.minY, f)
        let radius = min(lerp(fromRadius, toRadius, min(max(f, 0), 1)), min(width, height) / 2)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let contentAlpha = min(max((progress - 0.35) / 0.4, 0), 1)
        content
            .frame(width: to.width, height: to.height, alignment: .top)
            .scaleEffect(lerp(0.86, 1, min(max(progress, 0), 1)), anchor: contentAnchor)
            .opacity(contentAlpha)
            .frame(width: width, height: height, alignment: Alignment(horizontal: contentAnchor.x < 0.5 ? .leading : .trailing,
                                                                       vertical: contentAnchor.y < 0.5 ? .top : .bottom))
            .clipShape(shape)
            .glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
            .offset(x: x, y: y)
            .allowsHitTesting(progress > 0.6)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

// MARK: - Rows

/// A row of a glass action menu, iOS style: title on the leading side, symbol on the trailing side, 48 pt tall.
/// `isSelected` shows a leading checkmark (pickers); `isDestructive` draws it in the error colour.
struct GlassMenuItem: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isSelected: Bool?
    var isDestructive = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.glassMenuDismiss) private var dismissMenu

    init(_ title: LocalizedStringKey, systemImage: String? = nil, isSelected: Bool? = nil,
         isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        let color = isDestructive ? theme.error : theme.onSurface
        Button {
            dismissMenu?()
            action()
        } label: {
            HStack(spacing: 10) {
                if let isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 18)
                }
                Text(title)
                    .pixlFont(.bodyLarge, weight: .semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 24)
                }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(GlassMenuRowStyle())
        .accessibilityAddTraits(isSelected == true ? [.isButton, .isSelected] : .isButton)
    }
}

/// A thin separator between groups of menu rows.
struct GlassMenuDivider: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.onSurface.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
    }
}

/// A small heading above a group of rows.
struct GlassMenuHeader: View {
    let title: LocalizedStringKey
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(title)
            .pixlFont(.labelMedium, weight: .semibold)
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Immediate press highlight for menu rows (a soft fill under the finger, no glass on glass).
private struct GlassMenuRowStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(theme.onSurface.opacity(configuration.isPressed ? 0.1 : 0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
