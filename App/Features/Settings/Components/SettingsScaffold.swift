import SwiftUI
import UIKit

/// The collapsing header every settings screen uses (Android `CollapsibleCommonTopBar` driven by the screen's
/// nested-scroll connection): 180 dp tall including the status bar when expanded (≈128 pt below the iOS status bar),
/// 64 pt when collapsed. The title is `headlineMedium` bold at 1.2× expanded / 0.8× collapsed, bottom-left 20 pt in
/// when expanded and top-left 68 pt in (next to the back circle) when collapsed. The back button is a 40 pt glass
/// circle 12 pt in and 4 pt down; actions sit top-right. As the header collapses it fills with glass (Android's
/// `surfaceContainerHigh` ramp, `alpha = fraction × 2`) so the list scrolled under it stays masked.
///
/// The list moves 1:1 with the header (Android consumes the scroll for the header first, then the list), and a
/// release mid-way snaps to fully expanded or collapsed (Android `animateTo(…, StiffnessMedium)`).
///
/// Performance: the scroll offset lives in `SettingsHeaderState`, read only by the header — the screen body and its
/// rows never re-evaluate while scrolling.
struct SettingsScaffold<Content: View, Actions: View>: View {
    let title: String
    let screenID: String
    var expandedHeight: CGFloat = SettingsMetrics.headerExpanded
    var titleMaxLines = 1
    var expandedTitleLeading: CGFloat = 20
    var collapsedTitleLeading: CGFloat = 68
    var horizontalPadding: CGFloat = 16
    var spacing: CGFloat = 0
    var onBack: (() -> Void)?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    @State private var header = SettingsHeaderState()
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    init(title: String, screenID: String, expandedHeight: CGFloat = SettingsMetrics.headerExpanded,
         titleMaxLines: Int = 1, expandedTitleLeading: CGFloat = 20, collapsedTitleLeading: CGFloat = 68,
         horizontalPadding: CGFloat = 16, spacing: CGFloat = 0, onBack: (() -> Void)? = nil,
         @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title
        self.screenID = screenID
        self.expandedHeight = expandedHeight
        self.titleMaxLines = titleMaxLines
        self.expandedTitleLeading = expandedTitleLeading
        self.collapsedTitleLeading = collapsedTitleLeading
        self.horizontalPadding = horizontalPadding
        self.spacing = spacing
        self.onBack = onBack
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        let distance = expandedHeight - SettingsMetrics.headerCollapsed
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, expandedHeight + 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: SettingsScrollMetrics.self) { geometry in
                SettingsScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                      insetTop: geometry.contentInsets.top)
            } action: { _, metrics in
                if header.insetTop != metrics.insetTop { header.insetTop = metrics.insetTop }
                header.offset = metrics.offset
            }
            .scrollTargetBehavior(SettingsHeaderSnap(distance: distance, insetTop: header.insetTop))
            .accessibilityIdentifier("screen.\(screenID)")

            SettingsCollapsingTopBar(title: title, header: header, expandedHeight: expandedHeight,
                                     titleMaxLines: titleMaxLines, expandedTitleLeading: expandedTitleLeading,
                                     collapsedTitleLeading: collapsedTitleLeading,
                                     onBack: { if let onBack { onBack() } else { dismiss() } }) {
                actions
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(SettingsBackSwipeEnabler().frame(width: 0, height: 0))
    }
}

extension SettingsScaffold where Actions == EmptyView {
    init(title: String, screenID: String, expandedHeight: CGFloat = SettingsMetrics.headerExpanded,
         titleMaxLines: Int = 1, expandedTitleLeading: CGFloat = 20, collapsedTitleLeading: CGFloat = 68,
         horizontalPadding: CGFloat = 16, spacing: CGFloat = 0, onBack: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, screenID: screenID, expandedHeight: expandedHeight, titleMaxLines: titleMaxLines,
                  expandedTitleLeading: expandedTitleLeading, collapsedTitleLeading: collapsedTitleLeading,
                  horizontalPadding: horizontalPadding, spacing: spacing, onBack: onBack,
                  actions: { EmptyView() }, content: content)
    }
}

/// Values taken from the settings screens' Compose code.
nonisolated enum SettingsMetrics {
    /// `maxTopBarHeight` 180 dp minus Android's status bar (≈52 dp on the reference phone).
    static let headerExpanded: CGFloat = 128
    /// Long category titles (> 13 characters) get a 200 dp header with two title lines.
    static let headerExpandedLong: CGFloat = 148
    /// `minTopBarHeight` = 64 dp + status bar.
    static let headerCollapsed: CGFloat = 64
    /// Section rows: Surface corners 10 dp inside a 24 dp clipped group, 2 dp apart (`SettingsSubsection`).
    static let rowInnerRadius: CGFloat = 10
    static let groupRadius: CGFloat = 24
    static let rowSpacing: CGFloat = 2
}

nonisolated struct SettingsScrollMetrics: Equatable {
    var offset: CGFloat
    var insetTop: CGFloat
}

/// The header's scroll state. `offset` changes every frame and is read only by the header; `insetTop` (the scroll
/// view's top inset) changes once after the first layout and feeds the snap behaviour.
@Observable
final class SettingsHeaderState {
    var offset: CGFloat = 0
    var insetTop: CGFloat = 0
}

/// Snaps a release in the middle of the collapse to fully expanded or collapsed.
nonisolated struct SettingsHeaderSnap: ScrollTargetBehavior {
    let distance: CGFloat
    let insetTop: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let inset = insetTop
        let resting = target.rect.minY + inset
        guard resting > 0, resting < distance else { return }
        target.rect.origin.y = (resting < distance / 2 ? 0 : distance) - inset
    }
}

/// Android `CollapsibleCommonTopBar` + `ExpressiveTopBarContent`.
struct SettingsCollapsingTopBar<Actions: View>: View {
    let title: String
    let header: SettingsHeaderState
    let expandedHeight: CGFloat
    var titleMaxLines = 1
    var expandedTitleLeading: CGFloat = 20
    var collapsedTitleLeading: CGFloat = 68
    let onBack: () -> Void
    @ViewBuilder var actions: Actions

    @Environment(\.appTheme) private var theme

    var body: some View {
        let collapsed = SettingsMetrics.headerCollapsed
        let distance = max(expandedHeight - collapsed, 1)
        let height = min(max(expandedHeight - header.offset, collapsed), expandedHeight)
        let fraction = min(max((expandedHeight - height) / distance, 0), 1)
        let solidAlpha = min(fraction * 2, 1)
        let containerHeight = lerp(88, 56, fraction)
        let titleSize = 28 * lerp(1.2, 0.8, fraction)
        let leading = lerp(expandedTitleLeading, collapsedTitleLeading, fraction)
        // verticalBias 1 (bottom) → -1 (top).
        let titleTop = (height - containerHeight) * (1 - fraction)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .pixlGlass(in: Rectangle(), tint: theme.surfaceContainerHigh.opacity(GlassTint.bar))
                .opacity(solidAlpha)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(theme.onSurface)
                .lineLimit(titleMaxLines)
                .multilineTextAlignment(.leading)
                .frame(height: containerHeight, alignment: .leading)
                .padding(.leading, leading)
                .padding(.trailing, 24)
                .offset(y: titleTop)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                GlassCircleButton(systemImage: "arrow.left", accessibilityLabel: "Back",
                                  tint: theme.surfaceContainerLow.opacity(GlassTint.surface), action: onBack)
                    .accessibilityIdentifier("settings.back")
                Spacer(minLength: 0)
                HStack(spacing: 0) { actions }
            }
            .padding(.leading, 12)
            .padding(.top, 4)
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// Keeps the edge back-swipe working on screens that draw their own top bar (the system navigation bar is hidden):
/// installs a gesture delegate that allows the interactive pop whenever there is something to pop.
struct SettingsBackSwipeEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = ProbeController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class ProbeController: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController, let coordinator else { return }
            coordinator.navigation = navigation
            navigation.interactivePopGestureRecognizer?.delegate = coordinator
            navigation.interactivePopGestureRecognizer?.isEnabled = true
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigation: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigation?.viewControllers.count ?? 0) > 1
        }
    }
}

// MARK: - Toast (Android `Toast.makeText`)

/// A short-lived message capsule above the bottom bars (Android toasts), as glass.
struct SettingsToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .pixlFont(.bodyMedium, weight: .medium)
                    .foregroundStyle(theme.onSurface)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHighest.opacity(GlassTint.bar))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(PixlMotion.bars) { self.message = nil }
                    }
                    .accessibilityIdentifier("settings.toast")
            }
        }
        .animation(PixlMotion.bars, value: message)
    }
}

extension View {
    func settingsToast(_ message: Binding<String?>) -> some View {
        modifier(SettingsToastModifier(message: message))
    }
}
