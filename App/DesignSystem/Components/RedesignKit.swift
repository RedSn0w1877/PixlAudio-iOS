import SwiftUI

/// Redesign batch 2 kit (Library, Search, Queue, Ask Taizo, Settings), the port of Android's
/// `presentation/components/redesign/RedesignKit.kt` (branch `redesign-2`). Every number is Android's (1 dp = 1 pt,
/// 1 sp = 1 pt); only the Material surfaces become Liquid Glass: a filled button / chip / group segment / grouped row is
/// a glass shape tinted with Android's fill role (`GlassTint`), text keeps Android's `on…` role.
///
/// Performance: the shapes are value types built once per layout; the badge outlines are sampled once per size and
/// cached (`ExpressiveBadgeShape.cache`), so a list row asking for its badge allocates nothing per frame.
nonisolated enum Redesign {
    /// Screen side gutter.
    static let gutter: CGFloat = 16
    /// Header square buttons: 48 pt, 16 pt corners, 24 dp icon (≈ 20 pt symbol).
    static let headerButtonSize: CGFloat = 48
    static let headerButtonCorner: CGFloat = 16
    /// Filter chips: 36 pt tall, 10 pt corners.
    static let chipHeight: CGFloat = 36
    static let chipCorner: CGFloat = 10
    /// Connected button groups: 2 pt gaps.
    static let groupGap: CGFloat = 2
    /// Grouped rows: 20 pt outer, 4 pt inner corners, 2 pt apart.
    static let rowOuterCorner: CGFloat = 20
    static let rowInnerCorner: CGFloat = 4
    static let rowGap: CGFloat = 2
    /// A grouped row's minimum height.
    static let rowMinHeight: CGFloat = 52
}

/// `RedesignType`: the redesign's text styles in SF Pro (Android Google Sans Flex flat, same size / line / tracking).
extension PixlTextStyle {
    /// "Library", "Search", "Settings": 36/44 bold, −0.5.
    static let redesignScreenTitle = PixlTextStyle.custom(size: 36, weight: .bold, lineHeight: 44, tracking: -0.5)
    /// Queue, Taizo: 28/34 bold, −0.3 (Search with results uses 28/36).
    static let redesignCompactTitle = PixlTextStyle.custom(size: 28, weight: .bold, lineHeight: 34, tracking: -0.3)
    static let redesignRowTitle = PixlTextStyle.custom(size: 16, weight: .medium, lineHeight: 22)
    static let redesignRowSubtitle = PixlTextStyle.custom(size: 13, lineHeight: 18)
    static let redesignLabel = PixlTextStyle.custom(size: 14, weight: .medium, lineHeight: 20)
    static let redesignSectionTitle = PixlTextStyle.custom(size: 18, weight: .bold, lineHeight: 22)
}

/// The big screen title as a heading (one line).
struct RedesignScreenTitle: View {
    let text: LocalizedStringKey
    var style: PixlTextStyle = .redesignScreenTitle
    @Environment(\.appTheme) private var theme

    init(_ text: LocalizedStringKey, style: PixlTextStyle = .redesignScreenTitle) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .pixlFont(style)
            .foregroundStyle(theme.onSurface)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The header square button (New playlist, Shuffle, Settings, New chat): 48 pt, 16 pt corners, a 24 dp icon. Android
/// fills it `primaryContainer` (the accent action) or `surfaceContainerHigh` (neutral); here it is interactive glass
/// tinted with that role.
struct RedesignHeaderButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var accent = false
    var iconSize: CGFloat = 20
    var enabled = true
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Redesign.headerButtonCorner, style: .continuous)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(accent ? theme.onPrimaryContainer : theme.onSurface)
                .frame(width: Redesign.headerButtonSize, height: Redesign.headerButtonSize)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .pixlGlass(in: shape,
                   tint: accent ? theme.primaryContainer.opacity(GlassTint.prominent)
                       : theme.surfaceContainerHigh.opacity(GlassTint.surface),
                   interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The filter chip (Library tabs, Edit): 36 pt, 10 pt corners. Selected = `secondaryContainer` glass with a leading
/// 18 dp check; unselected = clear glass with a 1 pt `outline` border and an `onSurfaceVariant` label. 14 pt side
/// padding, 10 before the check, 6 pt icon gap, label 14/20 medium.
struct RedesignFilterChip: View {
    let label: String
    let isSelected: Bool
    var leadingSystemImage: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Redesign.chipCorner, style: .continuous)
        let content = isSelected ? theme.onSecondaryContainer : theme.onSurfaceVariant
        let showCheck = isSelected && leadingSystemImage == nil
        Button(action: action) {
            HStack(spacing: 6) {
                if showCheck {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 18, height: 18)
                } else if let leadingSystemImage {
                    Image(systemName: leadingSystemImage).font(.system(size: 14, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                if !label.isEmpty {
                    Text(label).pixlFont(.redesignLabel).lineLimit(1)
                }
            }
            .foregroundStyle(content)
            .padding(.leading, showCheck || leadingSystemImage != nil ? 10 : 14)
            .padding(.trailing, label.isEmpty ? 10 : 14)
            .frame(height: Redesign.chipHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay {
            if !isSelected { shape.strokeBorder(theme.outline, lineWidth: 1).allowsHitTesting(false) }
        }
        .pixlGlass(in: shape, tint: isSelected ? theme.secondaryContainer.opacity(GlassTint.prominent) : nil,
                   interactive: true)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Where a button sits in a connected group: decides which corners are outer (round) and inner.
nonisolated enum GroupPosition: Sendable {
    case single, first, middle, last

    static func of(_ index: Int, count: Int) -> GroupPosition {
        if count <= 1 { return .single }
        if index == 0 { return .first }
        return index == count - 1 ? .last : .middle
    }
}

/// One button of a connected group (view toggles, queue actions, search filters): outer corner = height / 2, inner
/// `inner`; selected = `primary` glass / `onPrimary`, and its inner corners grow to the outer radius (fully round);
/// unselected = `surfaceContainerHigh` glass / `onSurfaceVariant`. Put a group in a `GlassEffectContainer` with
/// spacing below `Redesign.groupGap`.
struct RedesignGroupButton<Label: View>: View {
    let position: GroupPosition
    let isSelected: Bool
    var height: CGFloat = 40
    var inner: CGFloat = 6
    var horizontalPadding: CGFloat = 12
    /// The unselected fill role (Queue's group uses `surfaceContainerHighest`).
    var container: Color?
    let action: () -> Void
    @ViewBuilder let label: (Color) -> Label

    @Environment(\.appTheme) private var theme

    var body: some View {
        let outer = height / 2
        let innerCorner = isSelected ? outer : inner
        let start = position == .first || position == .single ? outer : innerCorner
        let end = position == .last || position == .single ? outer : innerCorner
        let shape = UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: start,
                                           bottomTrailingRadius: end, topTrailingRadius: end, style: .continuous)
        let fill = isSelected ? theme.primary.opacity(GlassTint.prominent)
            : (container ?? theme.surfaceContainerHigh).opacity(GlassTint.surface)
        Button(action: action) {
            HStack(spacing: 4) { label(isSelected ? theme.onPrimary : theme.onSurfaceVariant) }
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: fill, interactive: true)
        .animation(PixlMotion.selection, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Grouped list row shape: first 20/20/4/4, middle 4, last 4/4/20/20, alone 20.
nonisolated func groupedRowShape(index: Int, count: Int, outer: CGFloat = Redesign.rowOuterCorner,
                                 inner: CGFloat = Redesign.rowInnerCorner) -> UnevenRoundedRectangle {
    let top = count <= 1 || index == 0 ? outer : inner
    let bottom = count <= 1 || index == count - 1 ? outer : inner
    return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                  topTrailingRadius: top, style: .continuous)
}

/// The expressive shapes Android's mockups put behind icons (M3 Expressive `MaterialShapes`), in the order the
/// Settings frame cycles them.
nonisolated enum BadgeShapeKind: Int, CaseIterable, Sendable {
    case cookie9, sunny, flower, clover4, softBurst, cookie6, circle

    /// The Settings rows' cycle (Cookie9, Sunny, Flower, Clover4, SoftBurst, Cookie6).
    static func cycled(_ index: Int) -> BadgeShapeKind {
        BadgeShapeKind(rawValue: ((index % 6) + 6) % 6) ?? .cookie9
    }

    /// Lobes and how deep the valleys go (fraction of the radius), sampled to match the Material shapes' outlines.
    var lobes: Int {
        switch self {
        case .cookie9: 9
        case .sunny: 8
        case .flower: 8
        case .clover4: 4
        case .softBurst: 10
        case .cookie6: 6
        case .circle: 0
        }
    }

    var depth: Double {
        switch self {
        case .cookie9: 0.075
        case .sunny: 0.11
        case .flower: 0.17
        case .clover4: 0.24
        case .softBurst: 0.09
        case .cookie6: 0.1
        case .circle: 0
        }
    }

    /// Sharpness of the points (1 = a pure cosine scallop; > 1 rounds the valleys and sharpens the tips, like Sunny).
    var sharpness: Double {
        switch self {
        case .sunny: 2
        case .softBurst: 1.6
        case .clover4: 0.6
        default: 1
        }
    }
}

/// A `MaterialShapes`-like outline as a SwiftUI shape: a polar curve r(θ) = R·(1 − depth·v(θ)), v the valley profile
/// of `lobes` scallops. The unit outline is sampled once per kind and scaled to the rect, so drawing a badge costs a
/// path transform, not trigonometry.
nonisolated struct ExpressiveBadgeShape: Shape {
    let kind: BadgeShapeKind

    init(_ kind: BadgeShapeKind) { self.kind = kind }

    func path(in rect: CGRect) -> Path {
        if kind == .circle { return Circle().path(in: rect) }
        let unit = Self.unitPaths[kind.rawValue]
        return unit.applying(CGAffineTransform(a: rect.width / 2, b: 0, c: 0, d: rect.height / 2,
                                               tx: rect.midX, ty: rect.midY))
    }

    /// Unit outlines (radius 1, centred at the origin), one per kind, built once.
    private static let unitPaths: [Path] = BadgeShapeKind.allCases.map(unitPath)

    private static func unitPath(_ kind: BadgeShapeKind) -> Path {
        var path = Path()
        guard kind.lobes > 0 else {
            path.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            return path
        }
        let samples = 180
        for i in 0 ..< samples {
            // Start at 12 o'clock with a lobe there, as the Material shapes do.
            let theta = Double(i) / Double(samples) * 2 * .pi - .pi / 2
            let wave = (1 - cos(Double(kind.lobes) * (theta + .pi / 2))) / 2 // 0 at a tip, 1 in a valley
            let shaped = pow(wave, 1 / kind.sharpness)
            let r = 1 - kind.depth * shaped
            let point = CGPoint(x: r * cos(theta), y: r * sin(theta))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// An icon on an expressive shape (settings rows 40/20, Accounts card 52/26, Taizo avatar). It sits on glass rows, so
/// it is a fill, not glass.
struct ShapeBadge: View {
    let systemImage: String
    let shape: BadgeShapeKind
    let container: Color
    let content: Color
    var size: CGFloat = 40
    var iconSize: CGFloat = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize * 0.85, weight: .medium))
            .foregroundStyle(content)
            .frame(width: size, height: size)
            .background(ExpressiveBadgeShape(shape).fill(container))
            .accessibilityHidden(true)
    }
}

/// A section label above a group of rows: 14/20 medium, `primary`, 16 pt in, 6 pt under.
struct RedesignSectionLabel: View {
    let text: LocalizedStringKey
    var color: Color?
    @Environment(\.appTheme) private var theme

    init(_ text: LocalizedStringKey, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .pixlFont(.custom(size: 14, weight: .medium, lineHeight: 20, tracking: 0.1))
            .foregroundStyle(color ?? theme.primary)
            .padding(.leading, 16)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A grouped row (Settings): 52 pt min, `surfaceContainer` glass in its grouped shape, 12 pt start / 16 pt end padding
/// (12 with a trailing control), optional 40 pt badge and 14 pt gap, title 16/22 medium, subtitle 13/18 and value
/// 14/20 in `onSurfaceVariant`.
struct RedesignGroupedRow<Leading: View, Trailing: View>: View {
    let title: String
    let shape: UnevenRoundedRectangle
    var subtitle: String?
    var value: String?
    var minHeight: CGFloat = Redesign.rowMinHeight
    var action: (() -> Void)?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.appTheme) private var theme

    var body: some View {
        let hasTrailing = Trailing.self != EmptyView.self
        let row = HStack(spacing: 0) {
            if Leading.self != EmptyView.self {
                leading()
                Spacer().frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).pixlFont(.redesignRowTitle).foregroundStyle(theme.onSurface).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).pixlFont(.redesignRowSubtitle).foregroundStyle(theme.onSurfaceVariant).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !value.isEmpty {
                Spacer().frame(width: 8)
                Text(value).pixlFont(.custom(size: 14, lineHeight: 20)).foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            if hasTrailing {
                Spacer().frame(width: 8)
                trailing()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hasTrailing ? 12 : 16)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight)
        .contentShape(shape)

        Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
        .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: action != nil)
    }
}

extension RedesignGroupedRow where Trailing == EmptyView {
    init(title: String, shape: UnevenRoundedRectangle, subtitle: String? = nil, value: String? = nil,
         action: (() -> Void)? = nil, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, shape: shape, subtitle: subtitle, value: value, action: action, leading: leading,
                  trailing: { EmptyView() })
    }
}
