import PixlModel
import SwiftUI

// The mix page (redesign batch 3; Android `MixPage.kt`, mockup AndroidMix), shared by Daily Mix, Your Mix and the other made-for-you
// lists. Android's numbers (1 dp = 1 pt); the Material fills of the block become Liquid Glass tinted with their role, the cover is the
// page's own colour field (a fill, like the artwork it stands in for).
//
//   cover    400 pt edge to edge behind the top: the mix's container colour with a 320 pt Flower (accent) at right −90 / top −110, a 150 pt
//            Cookie9 (onContainer) at 30 / 60 and a 220 pt circle (primaryContainer; the accent on Your Mix) at −90 / 200; a scrim
//            surface 40 % → 0 (18 %) → 0 (46 %) → 62 % (70 %) → 100 %. No blur.
//   buttons  safe area + 20 pt, 16 pt gutter: Back left, Save (+) and More right, 48 pt neutral glass circles, 8 pt apart.
//   block    214 pt under the safe area, 14 pt gaps: tag pill 26 pt (13 pt corners, onContainer / container, 12/16 bold 0.3), title
//            52/56 heavy −1.2 (first word expanded, the rest compressed in onContainer), meta 14/20 onSurfaceVariant, "Why these?" card
//            (surfaceContainer glass, 20 pt corners, 12/14 pt padding, 18 pt sparkle in the accent, 10 pt gap, 14/20 with the lead-in
//            semibold onContainer), then the actions (56 pt, 10 pt gap): Remix (container glass, 28/28/28/8 corners, 20 dp icon,
//            15/20 medium) and the connected Shuffle (56 pt, primaryContainer, 28/8/8/28) + Play (76 × 56, primary, 8/28/28/8, 30 dp icon),
//            2 pt apart.

/// Which colours a mix page wears: Daily = tertiary, Your = primary, other lists = secondary.
nonisolated enum MixPageTone: Sendable {
    case tertiary, primary, secondary
}

/// The container, on-container and accent roles of a tone.
private struct MixColors {
    let container: Color
    let onContainer: Color
    let accent: Color

    init(_ tone: MixPageTone, _ theme: ThemeColors) {
        switch tone {
        case .tertiary: (container, onContainer, accent) = (theme.tertiaryContainer, theme.onTertiaryContainer, theme.tertiary)
        case .primary: (container, onContainer, accent) = (theme.primaryContainer, theme.onPrimaryContainer, theme.primary)
        case .secondary: (container, onContainer, accent) = (theme.secondaryContainer, theme.onSecondaryContainer, theme.secondary)
        }
    }
}

nonisolated enum MixPageText {
    /// "Daily Mix 1" → ("Daily", " Mix 1"): the first word wide, the rest narrow (Android `splitMixTitle`).
    static func split(_ title: String) -> (wide: String, accent: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let space = t.firstIndex(of: " "), space > t.startIndex else { return (t, "") }
        return (String(t[..<space]), String(t[space...]))
    }

    /// "Made for you · 50 songs · 2 h 41 min" from the real songs (Android `mixMetaLine`).
    static func meta(_ songs: [Song]) -> String {
        let totalMs = songs.reduce(Int64(0)) { $0 + max($1.duration, 0) }
        let minutes = Int(totalMs / 60_000)
        var parts = [HomeRedesignStrings.mixMadeForYou, HomeRedesignStrings.mixSongCount(songs.count)]
        if minutes > 0 {
            parts.append(minutes >= 60 ? HomeRedesignStrings.mixDurationHours(minutes / 60, minutes % 60)
                                       : HomeRedesignStrings.mixDurationMinutes(minutes))
        }
        return parts.joined(separator: " · ")
    }

    /// "Why these?": the list's own note when it has one, else what is true of its songs (Android `mixWhyLine`).
    static func why(note: String?, songCount: Int, novelCount: Int) -> String? {
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
        if songCount == 0 { return nil }
        return novelCount > 0 ? HomeRedesignStrings.mixWhyNew(novelCount) : HomeRedesignStrings.mixWhyFamiliar
    }
}

/// The cover drawn behind the top 400 pt.
private struct MixCover: View {
    let tone: MixPageTone
    @Environment(\.appTheme) private var theme

    var body: some View {
        let c = MixColors(tone, theme)
        let surface = theme.surface
        ZStack(alignment: .topLeading) {
            c.container
            ExpressiveBadgeShape(.flower).fill(c.accent)
                .frame(width: 320, height: 320)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: 90, y: -110)
            ExpressiveBadgeShape(.cookie9).fill(c.onContainer)
                .frame(width: 150, height: 150)
                .offset(x: 30, y: 60)
            Circle().fill(tone == .primary ? c.accent : theme.primaryContainer)
                .frame(width: 220, height: 220)
                .offset(x: -90, y: 200)
            LinearGradient(stops: [.init(color: surface.opacity(0.4), location: 0),
                                   .init(color: surface.opacity(0), location: 0.18),
                                   .init(color: surface.opacity(0), location: 0.46),
                                   .init(color: surface.opacity(0.62), location: 0.70),
                                   .init(color: surface, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 400)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The page's top block (Android `MixPageHero`): cover, tag, title, meta, "Why these?" and the actions. The list's first item.
struct MixPageHero: View {
    let tone: MixPageTone
    let tag: String
    let title: String
    let meta: String
    let why: String?
    /// The safe area's top inset (the cover runs under the status bar).
    let safeTop: CGFloat
    let onShuffle: () -> Void
    let onPlay: () -> Void
    var onRemix: (() -> Void)?
    var remixBusy = false
    var screenID = "mix"

    @Environment(\.appTheme) private var theme

    var body: some View {
        let c = MixColors(tone, theme)
        let parts = MixPageText.split(title)
        ZStack(alignment: .topLeading) {
            MixCover(tone: tone)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: tag)
                        .pixlFont(.custom(size: 12, weight: .bold, lineHeight: 16, tracking: 0.3))
                        .foregroundStyle(c.container)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(c.onContainer, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    TwoToneTitle(wide: parts.wide, accent: parts.accent, size: 52, tracking: -1.2, accentColor: c.onContainer)
                    Text(verbatim: meta)
                        .pixlFont(.custom(size: 14, lineHeight: 20))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                if let why, !why.isEmpty { whyCard(why, c) }
                actions(c)
            }
            .padding(.horizontal, 16)
            .padding(.top, safeTop + 214)
        }
    }

    private func whyCard(_ why: String, _ c: MixColors) -> some View {
        var lead = AttributedString(HomeRedesignStrings.mixWhyThese)
        lead.font = .system(size: 14, weight: .semibold)
        lead.foregroundColor = c.onContainer
        let text = lead + AttributedString(" " + why)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(c.accent)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .pixlFont(.custom(size: 14, lineHeight: 20))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(screenID).why")
    }

    private func actions(_ c: MixColors) -> some View {
        let remixShape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 8, bottomTrailingRadius: 28,
                                                topTrailingRadius: 28, style: .continuous)
        let shuffleShape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28, bottomTrailingRadius: 8,
                                                  topTrailingRadius: 8, style: .continuous)
        let playShape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, bottomTrailingRadius: 28,
                                               topTrailingRadius: 28, style: .continuous)
        return GlassEffectContainer(spacing: 1) {
            HStack(spacing: 10) {
                if let onRemix {
                    Button(action: onRemix) {
                        HStack(spacing: 8) {
                            if remixBusy {
                                ProgressView().tint(c.onContainer).frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            Text(verbatim: HomeRedesignStrings.mixRemix)
                                .pixlFont(.custom(size: 15, weight: .medium, lineHeight: 20))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(c.onContainer)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .contentShape(remixShape)
                    }
                    .buttonStyle(.plain)
                    .disabled(remixBusy)
                    .pixlGlass(in: remixShape, tint: c.container.opacity(GlassTint.prominent), interactive: !remixBusy)
                    .accessibilityIdentifier("\(screenID).remix")
                } else {
                    Spacer(minLength: 0)
                }
                HStack(spacing: 2) {
                    groupButton("shuffle", HomeRedesignStrings.shuffle, shape: shuffleShape, width: 56, icon: 20,
                                fill: theme.primaryContainer, content: theme.onPrimaryContainer, action: onShuffle)
                        .accessibilityIdentifier("\(screenID).shuffle")
                    groupButton("play.fill", HomeRedesignStrings.mixPlay(title), shape: playShape, width: 76, icon: 25,
                                fill: theme.primary, content: theme.onPrimary, action: onPlay)
                        .accessibilityIdentifier("\(screenID).play")
                }
            }
        }
        .frame(height: 56)
    }

    private func groupButton(_ symbol: String, _ label: String, shape: UnevenRoundedRectangle, width: CGFloat, icon: CGFloat,
                             fill: Color, content: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(content)
                .frame(width: width, height: 56)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: fill.opacity(GlassTint.prominent), interactive: true)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// The buttons floating over the page (Android `MixPageTopButtons`): Back, and Save / More when the page has them.
struct MixPageTopButtons: View {
    let screenID: String
    let onBack: () -> Void
    var onSave: (() -> Void)?
    var onMore: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        let tint = theme.surfaceContainerHigh.opacity(GlassTint.surface)
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.back),
                                  size: 48, iconSize: 20, tint: tint, action: onBack)
                    .accessibilityIdentifier("\(screenID).back")
                Spacer(minLength: 0)
                if let onSave {
                    GlassCircleButton(systemImage: "plus", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.mixSave),
                                      size: 48, iconSize: 20, tint: tint, action: onSave)
                        .accessibilityIdentifier("\(screenID).save")
                }
                if let onMore {
                    GlassCircleButton(systemImage: "ellipsis", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.mixMore),
                                      size: 48, iconSize: 20, tint: tint, action: onMore)
                        .accessibilityIdentifier("\(screenID).more")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }
}
