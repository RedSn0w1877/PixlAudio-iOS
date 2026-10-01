import SwiftUI

/// Android `PermissionPageLayout`: 24 pt padding, the title (32 pt, `displayMedium` weight) and the description
/// (`bodyLarge`, `onSurfaceVariant`) centred at the top, the icon collage filling the middle, then the page's extra
/// content and the filled primary button (32 × 16 padding, `titleMedium`; a check and "Permission Granted" once granted).
struct SetupPermissionPage<Content: View>: View {
    let title: String
    var granted = false
    let description: String
    let buttonText: String
    let icons: [String]
    var buttonEnabled = true
    let onGrant: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SetupPageHeader(title: title, subtitle: description, topSpacing: 16)
            SetupIconCollage(icons: icons)
                .frame(height: 220)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                content()
                Spacer().frame(height: 16)
                SetupFilledButton(title: buttonText, systemImage: granted ? "checkmark" : nil,
                                  isEnabled: buttonEnabled, action: onGrant)
                Spacer().frame(height: 16)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}

extension SetupPermissionPage where Content == EmptyView {
    init(title: String, granted: Bool = false, description: String, buttonText: String, icons: [String],
         buttonEnabled: Bool = true, onGrant: @escaping () -> Void) {
        self.init(title: title, granted: granted, description: description, buttonText: buttonText, icons: icons,
                  buttonEnabled: buttonEnabled, onGrant: onGrant, content: { EmptyView() })
    }
}

/// The centred page title and subtitle every setup page starts with.
struct SetupPageHeader: View {
    let title: String
    let subtitle: String
    var topSpacing: CGFloat = 16
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topSpacing)
            Text(title)
                .pixlFont(.custom(size: 32, weight: .bold, lineHeight: 44))
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 16)
            Text(subtitle)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Android's filled `Button` on the setup pages, as prominent glass in `primary` (disabled: untinted glass with
/// Material's 38 % content).
struct SetupFilledButton: View {
    let title: String
    var systemImage: String?
    var isEnabled = true
    var tint: Color?
    var foreground: Color?
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                }
                Text(title)
                    .pixlFont(.titleMedium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isEnabled ? (foreground ?? theme.onPrimary) : theme.onSurface.opacity(0.38))
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pixlGlass(in: Capsule(), tint: isEnabled ? (tint ?? theme.primary).opacity(GlassTint.prominent) : nil,
                   interactive: isEnabled)
    }
}

/// Android `TextButton(…) { Text("Skip / Not now") }`: plain `labelLarge` text in `primary`.
struct SetupTextButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(isEnabled ? theme.primary : theme.onSurface.opacity(0.38))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
        .disabled(!isEnabled)
    }
}

/// Android `PermissionIconCollage`: five icons on tiles scattered over the box — a large rounded tile in the centre
/// (−15°), circles at the top-left (15°) and bottom-right (5°), a rounded tile at the top-right (−20°) and a small one
/// at the bottom-left (10°), tinted `secondary`, `onSurface` 80 %, `primary`, `onSurface` 50 % and `tertiary`, each with
/// 16 pt padding. The tiles are glass in one container; the star-shaped tile becomes a circle (no Material shapes).
struct SetupIconCollage: View {
    let icons: [String]
    @Environment(\.appTheme) private var theme

    private struct Slot {
        let scale: CGFloat
        let alignment: Alignment
        let rotation: Double
        let isCircle: Bool
        let offset: (CGFloat, CGFloat) -> CGSize
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            // Android: `min = minOf(200.dp, height)` with the collage's default 200 dp height.
            let base = min(200, height)
            let slots: [Slot] = [
                Slot(scale: 0.8, alignment: .center, rotation: -15, isCircle: false) { _, _ in .zero },
                Slot(scale: 0.4, alignment: .topLeading, rotation: 15, isCircle: true) { _, h in CGSize(width: 15, height: h * 0.05) },
                Slot(scale: 0.4, alignment: .bottomTrailing, rotation: 5, isCircle: true) { _, h in CGSize(width: -15, height: -h * 0.05) },
                Slot(scale: 0.5, alignment: .topTrailing, rotation: -20, isCircle: false) { _, h in CGSize(width: -30, height: h * 0.1) },
                Slot(scale: 0.35, alignment: .bottomLeading, rotation: 10, isCircle: true) { _, h in CGSize(width: 30, height: -h * 0.1) },
            ]
            let colors: [Color] = [theme.secondary, theme.onSurface.opacity(0.8), theme.primary,
                                   theme.onSurface.opacity(0.5), theme.tertiary]
            GlassEffectContainer(spacing: 2) {
                ZStack {
                    ForEach(Array(icons.prefix(5).enumerated()), id: \.offset) { index, symbol in
                        let slot = slots[index]
                        let size = base * slot.scale
                        tile(symbol, size: size, color: colors[index], isCircle: slot.isCircle)
                            .rotationEffect(.degrees(slot.rotation))
                            .offset(slot.offset(proxy.size.width, height))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.alignment)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ symbol: String, size: CGFloat, color: Color, isCircle: Bool) -> some View {
        let icon = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(16 + size * 0.06)
            .frame(width: size, height: size)
        if isCircle {
            icon.glassEffect(Glass.regular.tint(theme.surfaceContainerHigh.opacity(GlassTint.container)), in: Circle())
        } else {
            icon.glassEffect(Glass.regular.tint(theme.surfaceContainerHigh.opacity(GlassTint.container)),
                             in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Android `SetupBottomBar`: a bar with 36 pt top corners and square bottom corners (`surfaceContainer`) — "Let's
/// Go!" (`titleLarge` bold, `primary`) on the first page, "Step n of m" (`bodyLarge`) after, sliding vertically on
/// change — and the 80 pt next / finish button (`primaryContainer`) that turns a full circle and changes shape on
/// every page (circle → 26 pt rounded square → leaf). The bar and the button are glass.
struct SetupBottomBar: View {
    let page: Int
    let pageCount: Int
    var isNextEnabled = true
    var isFinishEnabled = true
    let onNext: () -> Void
    let onFinish: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLastPage: Bool { page == pageCount - 1 }

    var body: some View {
        let enabled = isLastPage ? isFinishEnabled : isNextEnabled
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if page == 0 {
                    Text(L10n.setupLetsGo)
                        .pixlFont(.titleLarge, weight: .bold)
                        .foregroundStyle(theme.primary)
                        .transition(stepTransition)
                        .id("letsgo")
                } else {
                    Text(L10n.setupStepFormat(page, pageCount - 1))
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .transition(stepTransition)
                        .id("step\(page)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .clipped()

            Button(action: isLastPage ? onFinish : onNext) {
                Image(systemName: isLastPage ? (isFinishEnabled ? "checkmark" : "xmark") : "arrow.right")
                    .font(.system(size: 26, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(enabled ? theme.onPrimaryContainer : theme.onSurface.opacity(0.58))
                    .rotationEffect(.degrees(reduceMotion ? 0 : -Double(page) * 360))
                    .frame(width: 80, height: 80)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .glassEffect(Glass.regular.tint((enabled ? theme.primaryContainer : theme.surfaceContainerHighest)
                                                .opacity(GlassTint.prominent)).interactive(), in: shape)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(page) * 360))
            .animation(.spring(response: 0.9, dampingFraction: 0.82), value: page)
            .accessibilityLabel(isLastPage ? L10n.commonFinish : L10n.commonNext)
            .accessibilityIdentifier("setup.next")
        }
        .padding(12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear
                .glassEffect(Glass.regular.tint(theme.surfaceContainer.opacity(GlassTint.bar)),
                             in: UnevenRoundedRectangle(topLeadingRadius: 36, bottomLeadingRadius: 0,
                                                        bottomTrailingRadius: 0, topTrailingRadius: 36,
                                                        style: .continuous))
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(PixlMotion.state, value: page)
    }

    /// Android's corner values per `page % 3` (dp, clamped to half the 80 pt button): 50 → circle, 26, 18/50 leaf.
    private var shape: UnevenRoundedRectangle {
        switch page % 3 {
        case 0: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 40, bottomLeading: 40, bottomTrailing: 40,
                                                          topTrailing: 40), style: .continuous)
        case 1: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 26, bottomLeading: 26, bottomTrailing: 26,
                                                          topTrailing: 26), style: .continuous)
        default: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 40,
                                                           topTrailing: 40), style: .continuous)
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity))
    }
}
