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
        /// The split-pill bar (new UI, 2026-11-16): a big glass capsule (Home + Library) and a glass circle (Search)
        /// side by side, as tall as the approved mockup's 64 pt; shorter in compact mode (icons only).
        static let navBarHeight: CGFloat = 64
        static let navBarCompactHeight: CGFloat = 54
        /// The bar while a tab root scrolls down (2026-10-03): symbols only, the big capsule narrowed to
        /// `navBarMinimizedSegmentWidth` per tab and lowered to this height. Scrolling up or reaching the top restores it.
        static let navBarMinimizedHeight: CGFloat = 48
        static let navBarMinimizedSegmentWidth: CGFloat = 58
        /// Gap between the big capsule and the small circle (mockup: 10).
        static let navPillSpacing: CGFloat = 10
        /// Inset of the segments (and their selection capsule) inside the big capsule (mockup: 5).
        static let navPillPadding: CGFloat = 5
        /// Gap between the segments inside the big capsule (mockup: 4).
        static let navSegmentSpacing: CGFloat = 4
        /// Room between the bar and the keyboard while the bar's search field types.
        static let navKeyboardGap: CGFloat = 8
        /// Padding between a liquid-lens picker's glass capsule and its segmented control (as FabBar).
        static let navGlassPadding: CGFloat = 2
        /// `nav_bar_corner_radius` default (`NAV_BAR_CORNER_RADIUS ?: 32`): the mini player's corners (a capsule at
        /// 64 pt) and PixlAudio's large glass cards.
        static let navBarCornerRadius: CGFloat = 32
        /// Side inset of bar and mini player (`horizontalPadding`: 16 dp when the system inset is > 30 dp).
        static let horizontalInset: CGFloat = 16
        /// `MiniPlayerHeight`.
        static let miniPlayerHeight: CGFloat = 64
        /// The mini player floats this far above the split-pill bar as its own pill (new UI, 2026-11-16: the approved
        /// mockups leave 12–14 pt; Android's `MiniPlayerBottomSpacer` was 8).
        static let miniPlayerSpacing: CGFloat = 12
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
        /// The transport buttons' touch area (Compose extends small clickables to 48 dp; iOS asks for 44 pt): the
        /// 36 pt circles sit centred in it, so the 8 pt gaps between them are now part of the buttons.
        static let buttonHitSize: CGFloat = 44
        /// Play / pause inside its progress ring (new UI, 2026-11-16): the fill shrinks to leave room for the ring,
        /// which runs round the 44 pt touch area, 2.5 pt thick.
        static let playButtonSize: CGFloat = 34
        static let ringDiameter: CGFloat = 44
        static let ringLineWidth: CGFloat = 2.5
        /// Extra room each side of the ringed play button, so the ring clears the previous / next circles.
        static let ringSpacing: CGFloat = 2
    }

    /// The full player's bottom split pills (new UI, 2026-11-16, mockup `iOSPlayer`): a big capsule (shuffle, repeat,
    /// favourite) and a small circle (lyrics), like the bottom bar's pair.
    enum PlayerPills {
        static let height: CGFloat = 64
        static let padding: CGFloat = 5
        static let segmentSpacing: CGFloat = 4
        static let iconSize: CGFloat = 21
    }

    /// Page heroes (new UI, 2026-11-16, mockups `iOSArtist` / `iOSPlaylist`): the art fills the top edge to edge
    /// (`ProgressiveBlurHero`, `HeroHeader.height`), the title block sits on its blurred bottom.
    enum PageHero {
        /// Width ÷ height on a portrait phone (390 pt → 424 pt: the mockup's 360 pt plus the status bar).
        static let aspect: CGFloat = 0.92
        static let sidePadding: CGFloat = 16
        /// The pinned top bar under the status bar (the 40 pt back circle and the ⋯ menu, centred).
        static let barHeight: CGFloat = 56
        /// Play capsule and Shuffle circle.
        static let actionHeight: CGFloat = 52
        static let actionSpacing: CGFloat = 8
        /// Album tiles in the horizontal shelf.
        static let albumTile: CGFloat = 132
        static let albumCorner: CGFloat = 18
        static let albumSpacing: CGFloat = 12
        static let sectionSpacing: CGFloat = 24
        /// The playlist page's song card: inset from the screen edges, its corner radius.
        static let panelInset: CGFloat = 8
        static let panelCorner: CGFloat = 28
        /// The Find field pinned under the playlist page's bar (`ListFindField`: 8 + 48 + 4 pt).
        static let findFieldHeight: CGFloat = 60
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
