import PixlLibrary
import PixlModel
import SwiftUI

// The sections of the new Home (docs/brain-spec.md, 8.1, 8.10), one per Android component in `HomePlanSections.kt`. Geometry is
// copied from the Compose code; Material surfaces are glass tinted with the role Android filled them with. Every list is keyed
// by the plan's own ids; nothing here allocates per frame.

/// The chips under the greeting: For you, Mixes, Spatial, New.
nonisolated enum HomeChip: Int, CaseIterable, Sendable {
    case forYou, mixes, spatial, new

    var title: String {
        switch self {
        case .forYou: BrainStrings.chipForYou
        case .mixes: BrainStrings.chipMixes
        case .spatial: BrainStrings.chipSpatial
        case .new: BrainStrings.chipNew
        }
    }
}

// MARK: - Date line and chips

struct HomeDateLine: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(verbatim: text)
            .pixlFont(.labelLarge)
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HomeMetrics.greetingInset + 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.dateLine")
    }
}

struct HomeChipsRow: View {
    let selected: HomeChip
    /// The chips offered: one with nothing behind it (no mixes, nothing new) is not here, so no chip leads to a blank page.
    var chips: [HomeChip] = HomeChip.allCases
    let onSelect: (HomeChip) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.rawValue) { chip in
                        let isSelected = chip == selected
                        Button { onSelect(chip) } label: {
                            Text(verbatim: chip.title)
                                .pixlFont(.labelLarge)
                                .foregroundStyle(isSelected ? theme.onSecondaryContainer : theme.onSurface)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .pixlGlass(in: Capsule(),
                                   tint: (isSelected ? theme.secondaryContainer : theme.surfaceContainer)
                                       .opacity(isSelected ? GlassTint.container : GlassTint.surface),
                                   interactive: true)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("home.chip.\(chip.rawValue)")
                    }
                }
                .padding(.horizontal, HomeMetrics.greetingInset)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

// MARK: - Hero

/// The one big card at the top of the plan: First Listen on Mondays, a release from a top artist, or a Daily Mix.
struct HomeHeroCard: View {
    let hero: HeroUi
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.mixCard, style: .continuous)
        Button(action: onTap) {
            HStack(spacing: 16) {
                ArtworkView(source: ArtworkSource(uriString: hero.art), size: 104, cornerRadius: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: hero.title)
                        .pixlFont(.headlineSmall, weight: .bold)
                        .lineLimit(2)
                    if !hero.subtitle.isEmpty {
                        Text(verbatim: hero.subtitle)
                            .pixlFont(.bodyMedium)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(16)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.container), interactive: true)
        .padding(.horizontal, HomeMetrics.greetingInset)
        .accessibilityLabel(Text(verbatim: hero.title))
        .accessibilityIdentifier("home.hero")
    }
}

// MARK: - Jump back in

struct HomeJumpBackIn: View {
    let tiles: [TileUi]
    let onTile: (TileUi) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: BrainStrings.jumpBackIn)
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 20)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(tiles) { tile in tileView(tile) }
                }
                .padding(.horizontal, HomeMetrics.greetingInset)
            }
        }
    }

    private func tileView(_ tile: TileUi) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button { onTile(tile) } label: {
            HStack(spacing: 10) {
                ArtworkView(source: ArtworkSource(uriString: tile.art), size: 48, cornerRadius: 14)
                Text(verbatim: tile.title)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: true)
        .accessibilityIdentifier("home.tile.\(tile.key)")
    }
}

// MARK: - Mix and station shelves

/// A shelf of made-for-you cards (8.2): a Daily Mix per island, Your Mix, First Listen, Just Dropped, On Repeat, Rediscover.
struct HomeMixShelf: View {
    let title: String
    let subtitle: String
    let cards: [MixCardUi]
    let onOpen: (MixCardUi) -> Void
    /// "How it works" of the Endless Listening card's menu; nil leaves the menu out.
    var onEndlessHowItWorks: (() -> Void)?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomePlanHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 12) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            // The Endless Listening card has a colour of its own, so the mixes keep the colours they had before it joined the shelf.
                            cardView(card, index: card.kind == MixKinds.endless ? 2 : cards.prefix(index).filter { $0.kind != MixKinds.endless }.count)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func cardView(_ card: MixCardUi, index: Int) -> some View {
        let (container, content): (Color, Color) = switch index % 3 {
        case 0: (theme.primaryContainer, theme.onPrimaryContainer)
        case 1: (theme.secondaryContainer, theme.onSecondaryContainer)
        default: (theme.tertiaryContainer, theme.onTertiaryContainer)
        }
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.mixCard, style: .continuous)
        return Button { onOpen(card) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(Array(card.covers.prefix(3).enumerated()), id: \.offset) { _, art in
                        ArtworkView(source: ArtworkSource(uriString: art), size: 60, cornerRadius: 18)
                    }
                }
                .frame(height: 60, alignment: .leading)
                Text(verbatim: card.title)
                    .pixlFont(.titleLarge, weight: .bold)
                    .lineLimit(1)
                Text(verbatim: card.subtitle)
                    .pixlFont(.bodyMedium)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 0) {
                    // A station has no song count: it says what it does.
                    Text(verbatim: card.kind == MixKinds.endless ? EndlessStrings.cardTag : BrainStrings.songsCount(card.count))
                        .pixlFont(.labelLarge)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(content)
            .padding(18)
            .frame(width: 236, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: container.opacity(GlassTint.container), interactive: true)
        .accessibilityLabel(Text(verbatim: card.title))
        .accessibilityIdentifier("home.mix.\(card.mixId)")
        // The menu of the Endless Listening card: "How it works" replays the introduction. The long press is the card's own, so the
        // menu is a context menu and no second control sits over the glass. Only that card gets one: a menu with nothing in it on every
        // other card might still take the long press.
        .modifier(EndlessCardMenu(howItWorks: card.kind == MixKinds.endless ? onEndlessHowItWorks : nil))
    }
}

/// The context menu of the Endless Listening card, or nothing at all when there is no action.
private struct EndlessCardMenu: ViewModifier {
    let howItWorks: (() -> Void)?

    func body(content: Content) -> some View {
        if let howItWorks {
            content.contextMenu {
                Button(EndlessStrings.howItWorks, systemImage: "questionmark.circle", action: howItWorks)
            }
        } else {
            content
        }
    }
}

/// "Stations for you" (8.1): genre and mood cards; a tap starts the station.
struct HomeStationShelf: View {
    let title: String
    let subtitle: String
    let cards: [StationCardUi]
    let onStart: (StationCardUi) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomePlanHeader(title: title, subtitle: subtitle)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in cardView(card) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func cardView(_ card: StationCardUi) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.large, style: .continuous)
        return Button { onStart(card) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(source: ArtworkSource(uriString: card.covers.first), size: 136, cornerRadius: 18)
                Text(verbatim: card.name)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(verbatim: BrainStrings.songsCount(card.count))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(10)
            .frame(width: 156, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: true)
        .accessibilityLabel(Text(verbatim: BrainStrings.stationTitle(card.name)))
        .accessibilityIdentifier("home.station.\(card.id)")
    }
}

/// The "Mixes" chip: every made-for-you card in a grid.
struct HomeAllMixes: View {
    let cards: [MixCardUi]
    let onOpen: (MixCardUi) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomePlanHeader(title: BrainStrings.homeMadeForYou, subtitle: "")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(cards) { card in
                    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                    Button { onOpen(card) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(source: ArtworkSource(uriString: card.covers.first), size: 120, cornerRadius: 18)
                            Text(verbatim: card.title).pixlFont(.titleSmall, weight: .bold).lineLimit(1)
                            Text(verbatim: card.subtitle.isEmpty ? BrainStrings.songsCount(card.count) : card.subtitle)
                                .pixlFont(.bodySmall)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .foregroundStyle(theme.onSurface)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: true)
                    .accessibilityIdentifier("home.allmixes.\(card.mixId)")
                }
            }
            .padding(.horizontal, HomeMetrics.greetingInset)
        }
    }
}

private struct HomePlanHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

// MARK: - The first minute (8.10)

/// "Getting to know your music · 3 of 8": a quiet strip, never a spinner and never an empty state.
struct HomeKnowingStrip: View {
    let done: Int
    let total: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(theme.primary)
                .frame(width: 56)
            Text(verbatim: BrainStrings.gettingToKnow(done, total))
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("home.knowing")
    }
}

/// "Pick three artists you love": offered to a thin library.
struct HomeArtistPickerCard: View {
    let onPick: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.mixCard, style: .continuous)
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: BrainStrings.pickArtistsTitle).pixlFont(.titleLarge, weight: .bold)
                Text(verbatim: BrainStrings.artistPickerCard).pixlFont(.bodyMedium)
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.container), interactive: true)
        .padding(.horizontal, HomeMetrics.greetingInset)
        .accessibilityIdentifier("home.artistPicker")
    }
}
