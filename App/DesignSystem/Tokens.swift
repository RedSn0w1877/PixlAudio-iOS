import SwiftUI

/// Layout constants taken from PixlAudio's Compose code (1 dp = 1 pt). Each value names its Android source so a
/// stage porting a screen can check it. Colours come from `ThemeColors`; type from `PixlTextStyle`.
nonisolated enum Tokens {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// Android `ui/theme/Shape.kt` plus the component radii PixlAudio uses everywhere.
    enum Radius {
        static let small: CGFloat = 8          // Shapes.small
        static let medium: CGFloat = 16        // Shapes.medium
        static let large: CGFloat = 24         // Shapes.large
        static let card: CGFloat = 28          // HomeGreetingCard default
        static let mixCard: CGFloat = 32       // HomeDiscoveryMixes cards
        static let contentPanel: CGFloat = 34  // LibraryScreen content surface (top corners)
        static let quickAction: CGFloat = 20   // HomeQuickActionsRow pill
    }

    /// Shell geometry (MainActivity, PlayerInternalNavigationBar, UnifiedPlayerSheetShared, SheetVisualState).
    enum Shell {
        /// The iOS-style tab bar (2026-10-01, replaces Android's compact bar): a floating glass capsule as tall as
        /// the system tab bar with labels, shorter in compact mode (icons only).
        static let navBarHeight: CGFloat = 62
        static let navBarCompactHeight: CGFloat = 54
        /// Gap between the tab bar's edge and its accent selection pill.
        static let navPillInset: CGFloat = 4
        /// `nav_bar_corner_radius` default (`NAV_BAR_CORNER_RADIUS ?: 32`): the mini player's corners (a capsule at
        /// 64 pt) and PixlAudio's large glass cards.
        static let navBarCornerRadius: CGFloat = 32
        /// Side inset of bar and mini player (`horizontalPadding`: 16 dp when the system inset is > 30 dp).
        static let horizontalInset: CGFloat = 16
        /// `MiniPlayerHeight`.
        static let miniPlayerHeight: CGFloat = 64
        /// `MiniPlayerBottomSpacer`: the mini player floats this far above the tab bar.
        static let miniPlayerSpacing: CGFloat = 8
    }

    /// Mini player content (`MiniPlayerContentInternal`).
    enum MiniPlayer {
        static let artSize: CGFloat = 44
        static let leadingPadding: CGFloat = 10
        static let trailingPadding: CGFloat = 12
        static let artSpacing: CGFloat = 12
        static let buttonSize: CGFloat = 36
        static let buttonIconSize: CGFloat = 22
        static let buttonSpacing: CGFloat = 8
    }

    /// Song list item (`EnhancedSongListItem`).
    enum SongCard {
        static let cornerRadius: CGFloat = 22
        static let artSize: CGFloat = 50
        static let artCornerRadius: CGFloat = 10
        static let horizontalPadding: CGFloat = 13
        static let verticalPadding: CGFloat = 12
        static let artSpacing: CGFloat = 14
        static let titleArtistSpacing: CGFloat = 4
        static let trailingSpacing: CGFloat = 12
        static let moreButtonSize: CGFloat = 36
        static let moreButtonEndPadding: CGFloat = 4
        static let moreIconSize: CGFloat = 24
        static let listSpacing: CGFloat = 8
    }

    /// Top bars (`TopAppBar` + PixlAudio's actions).
    enum TopBar {
        static let height: CGFloat = 64
        /// Title start: TopAppBar's 16 dp + the title's own 8 dp.
        static let titleLeading: CGFloat = 24
        /// Action end: 14 dp padding + TopAppBar's 4 dp.
        static let actionTrailing: CGFloat = 18
        static let actionSpacing: CGFloat = 6
        static let circleButtonSize: CGFloat = 40
        static let circleIconSize: CGFloat = 24
    }

    /// Library category tabs (`TabAnimation` inside `PrimaryScrollableTabRow`).
    enum Tabs {
        static let height: CGFloat = 48
        static let outerPadding: CGFloat = 5
        static let textHorizontalPadding: CGFloat = 16
        static let edgePadding: CGFloat = 12
    }

    enum Artwork {
        static let rowSize: CGFloat = 50
        static let rowCornerRadius: CGFloat = 10
        static let tileCornerRadius: CGFloat = 16
    }
}
