import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI
import UIKit

/// What Search shows while the query is empty (Android `GenreCategoriesGrid`): "Browse categories" — sixteen fixed
/// catalogue categories that open the catalogue browser — then "Browse by genre" with the grid/list toggle and the
/// library's genres. 18 pt side padding, 12 pt gaps, the top corners clipped at 24 pt. Material cards become glass
/// tinted with the genre colour (one glass layer per card).
struct GenreBrowseView: View {
    let genres: [Genre]
    @Binding var isGridView: Bool
    let onGenre: (Genre) -> Void
    let onCategory: (SearchCategory) -> Void

    @Environment(\.appTheme) private var theme

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: isGridView ? 2 : 1)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Browse categories")
                    .pixlFont(.titleLarge, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SearchCategory.defaults) { category in
                        SearchCategoryCard(category: category) { onCategory(category) }
                    }
                }
                if genres.isEmpty {
                    Text("No genres available.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .padding(.leading, 6)
                        .padding(.top, 24)
                } else {
                    genresHeader
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(genres) { genre in
                            GenreCard(genre: genre, isGridView: isGridView) { onGenre(genre) }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 18)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                          topTrailingRadius: 24, style: .continuous))
        .accessibilityIdentifier("search.genreGrid")
    }

    private var genresHeader: some View {
        HStack {
            Text("Browse by genre")
                .pixlFont(.titleLarge)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // FilledIconButton (secondaryContainer) whose corners animate 12 dp (list) ↔ round (grid).
            let shape = RoundedRectangle(cornerRadius: isGridView ? 20 : 12, style: .continuous)
            Button {
                withAnimation(PixlMotion.state) { isGridView.toggle() }
            } label: {
                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 40, height: 40)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: shape, tint: theme.secondaryContainer.opacity(GlassTint.container), interactive: true)
            .accessibilityLabel("Toggle Grid/List View")
            .accessibilityIdentifier("search.genreViewToggle")
        }
        .padding(.leading, 6)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

/// Android `SearchCategoryCard`: 1.45 : 1, 24 pt corners, the category's genre colour, its glyph rotated −14°
/// at 32 % out of the bottom-trailing corner, the name (20 pt bold, two lines, 78 % wide) top-leading.
struct SearchCategoryCard: View {
    let category: SearchCategory
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = GenreCardPalette.color(genreId: category.id, isDark: colorScheme == .dark)
        let onContainer = Color(argb: colors.onContainer)
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        Button(action: action) {
            Color.clear
                .aspectRatio(1.45, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    GenreIconImage(icon: .forGenre(category.name), color: onContainer)
                        .scaledToFit()
                        .padding(.leading, 8)
                        .padding(.top, 8)
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(-14))
                        .opacity(0.32)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    GeometryReader { proxy in
                        Text(category.name)
                            .pixlFont(.custom(size: 20, weight: .bold, lineHeight: 28))
                            .foregroundStyle(onContainer)
                            .lineLimit(2)
                            .padding(.leading, 16)
                            .padding(.top, 14)
                            .padding(.trailing, 4)
                            .frame(width: proxy.size.width * 0.78, alignment: .leading)
                    }
                }
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: Color(argb: colors.container).opacity(GlassTint.container), interactive: true)
        .accessibilityLabel(category.name)
        .accessibilityIdentifier("search.category.\(category.id)")
    }
}

/// Android `GenreCard`: 1.2 : 1 in the grid, 100 pt tall in the list; 20 pt corners; the genre's colour; its
/// illustration (90 pt, 55 %) pushed 16 pt out of the bottom-trailing corner; the expressive title top-leading.
struct GenreCard: View {
    let genre: Genre
    let isGridView: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var title: GenreTitleTypography.Presentation?

    private static let titleStart: CGFloat = 14

    var body: some View {
        let colors = GenreCardPalette.color(for: genre, isDark: colorScheme == .dark)
        let onContainer = Color(argb: colors.onContainer)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let titleEnd: CGFloat = isGridView ? 14 : 96
        Button(action: action) {
            Group {
                if isGridView {
                    Color.clear.aspectRatio(1.2, contentMode: .fit)
                } else {
                    Color.clear.frame(height: 100)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                GenreIconImage(icon: .forGenre(genre.name), color: onContainer)
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipped()
                    .opacity(0.55)
                    .offset(x: 16, y: 16)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if let title {
                    GenreTitleView(presentation: title, color: onContainer)
                        .padding(.leading, Self.titleStart)
                        .padding(.top, 14)
                        .padding(.trailing, titleEnd)
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                let resolved = GenreTitleTypography.resolve(genreId: genre.id, name: genre.name, isGridView: isGridView,
                                                            cardWidth: width, horizontalPadding: (Self.titleStart + titleEnd) / 2)
                if resolved != title { title = resolved }
            }
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: Color(argb: colors.container).opacity(GlassTint.container), interactive: true)
        .accessibilityLabel(genre.name)
        .accessibilityIdentifier("search.genre.\(genre.id)")
    }
}

/// One or two lines of a genre title in its resolved style.
private struct GenreTitleView: View {
    let presentation: GenreTitleTypography.Presentation
    let color: Color

    var body: some View {
        let style = presentation.style
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: style.lineGap) {
                line(presentation.firstLine)
                    .frame(width: proxy.size.width, alignment: .leading)
                if let second = presentation.secondLine {
                    line(second)
                        .frame(width: proxy.size.width * presentation.secondLineWidthFraction, alignment: .leading)
                }
            }
        }
    }

    private func line(_ text: String) -> some View {
        let style = presentation.style
        return Text(text)
            .font(.system(size: style.size, weight: style.fontWeight))
            .fontWidth(style.fontWidth)
            .italic(style.isItalic)
            .tracking(style.tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Android `GenreTypography.resolveTitlePresentation`: per-genre "expressive" title styles (six candidates derived
/// from the genre id's hash), the first that fits on one line, else the best two-line break. Android varies Google
/// Sans Flex's axes; in SF Pro the size, weight, width (compressed…expanded), italic for strong slants and tracking
/// carry over. Text is measured with UIKit once per card width — never per frame.
nonisolated enum GenreTitleTypography {
    nonisolated struct Style: Hashable, Sendable {
        var size: CGFloat
        /// Variable-font weight (500…820).
        var weight: Int
        /// Variable-font width axis (72…166, 100 = normal).
        var width: CGFloat
        /// Variable-font slant in degrees (0…−12).
        var slant: CGFloat

        /// Android letter spacing by width.
        var tracking: CGFloat { width >= 136 ? -0.7 : (width >= 118 ? -0.45 : -0.18) }
        var isItalic: Bool { slant <= -6 }

        var fontWeight: Font.Weight {
            switch weight {
            case ..<550: .medium
            case ..<650: .semibold
            case ..<750: .bold
            default: .heavy
            }
        }

        var uiWeight: UIFont.Weight {
            switch weight {
            case ..<550: .medium
            case ..<650: .semibold
            case ..<750: .bold
            default: .heavy
            }
        }

        var fontWidth: Font.Width {
            switch width {
            case 125...: .expanded
            case 105...: .standard
            case 90...: .condensed
            default: .compressed
            }
        }

        var uiWidth: UIFont.Width {
            switch width {
            case 125...: .expanded
            case 105...: .standard
            case 90...: .condensed
            default: .compressed
            }
        }

        func uiFont() -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: uiWeight, width: uiWidth)
            guard isItalic, let italic = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
            return UIFont(descriptor: italic, size: size)
        }

        /// Compose line height is 0.92 × size; SwiftUI lays lines at the font's own height, so close the gap.
        var lineGap: CGFloat { size * 0.92 - uiFont().lineHeight }
    }

    nonisolated struct Presentation: Hashable, Sendable {
        var firstLine: String
        var secondLine: String?
        var style: Style
        var secondLineWidthFraction: CGFloat
    }

    nonisolated private struct Profile {
        let totalChars: Int
        let wordCount: Int
        let longestWord: Int
        var isCompact: Bool { totalChars <= 8 && wordCount <= 2 && longestWord <= 8 }
        var isDense: Bool { totalChars >= 14 || wordCount >= 3 || longestWord >= 10 }
        var isVeryDense: Bool { totalChars >= 18 || wordCount >= 4 || longestWord >= 13 }

        init(_ text: String) {
            let words = text.split(separator: " ").filter { !$0.isEmpty }
            totalChars = text.utf16.count
            wordCount = words.count
            longestWord = words.map { $0.utf16.count }.max() ?? text.utf16.count
        }
    }

    static func resolve(genreId: String, name: String, isGridView: Bool, cardWidth: CGFloat,
                        horizontalPadding: CGFloat) -> Presentation {
        let normalized = name.kotlinTrimmed().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let profile = Profile(normalized)
        let hash = Int64(KotlinText.hashCode(genreId)).magnitude
        let fullWidth = max(cardWidth - horizontalPadding * 2, 0)
        let fraction = secondLineFraction(profile, isGridView: isGridView)
        let secondWidth = max((fullWidth * fraction).rounded(), 0)
        let words = normalized.split(separator: " ").map(String.init)
        let candidates = styleCandidates(hash: hash, profile: profile, isGridView: isGridView)

        for style in candidates {
            if measure(normalized, style) <= fullWidth {
                return Presentation(firstLine: normalized, secondLine: nil, style: style, secondLineWidthFraction: fraction)
            }
            if words.count > 1, let best = bestBreak(words, style, fullWidth, secondWidth, allowOverflow: false) {
                return Presentation(firstLine: best.0, secondLine: best.1, style: style, secondLineWidthFraction: fraction)
            }
        }
        let fallback = candidates[candidates.count - 1]
        let best = words.count > 1 ? bestBreak(words, fallback, fullWidth, secondWidth, allowOverflow: true) : nil
        return Presentation(firstLine: best?.0 ?? normalized, secondLine: best?.1, style: fallback,
                            secondLineWidthFraction: fraction)
    }

    static func measure(_ text: String, _ style: Style) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: style.uiFont(), .kern: style.tracking]).width.rounded(.up)
    }

    private static func bestBreak(_ words: [String], _ style: Style, _ firstWidth: CGFloat, _ secondWidth: CGFloat,
                                  allowOverflow: Bool) -> (String, String)? {
        var best: (String, String, Double)?
        for index in 1..<words.count {
            let first = words[..<index].joined(separator: " ")
            let second = words[index...].joined(separator: " ")
            let firstMeasured = measure(first, style)
            guard firstMeasured <= firstWidth else { continue }
            let secondMeasured = measure(second, style)
            let overflows = secondMeasured > secondWidth
            if !allowOverflow, overflows { continue }
            let firstUsage = Double(min(firstMeasured, firstWidth) / max(firstWidth, 1))
            let secondUsage = Double(min(secondMeasured, secondWidth) / max(secondWidth, 1))
            let orphan = Double([first, second].filter { $0.utf16.count <= 3 }.count) * 0.35
            let lastWord = second.split(separator: " ").last.map(String.init) ?? second
            let tiny = lastWord.utf16.count <= 2 ? 0.25 : 0
            let overflowPenalty = allowOverflow && overflows ? 0.45 : 0
            let score = firstUsage * 1.8 + min(secondUsage, 1) * 0.8 - orphan - tiny - overflowPenalty
            if best == nil || score > best!.2 { best = (first, second, score) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func secondLineFraction(_ profile: Profile, isGridView: Bool) -> CGFloat {
        if isGridView && profile.wordCount >= 3 { return 0.56 }
        if isGridView { return 0.52 }
        return 1
    }

    private static func jitter(_ hash: UInt64, _ divisor: UInt64, _ span: Double) -> Double {
        let normalized = Double((hash / divisor) % 1000) / 999
        return (normalized - 0.5) * span
    }

    private static func slant(_ hash: UInt64, _ divisor: UInt64, _ options: [Double]) -> Double {
        options[Int((hash / divisor) % UInt64(options.count))]
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    /// `buildStyleCandidates` (the axes SF Pro has: size, weight, width, slant).
    private static func styleCandidates(hash: UInt64, profile: Profile, isGridView: Bool) -> [Style] {
        let base: Double
        if isGridView {
            base = profile.isVeryDense ? 24 : (profile.isDense ? 26 : (profile.isCompact ? 30 : 28))
        } else {
            base = profile.isVeryDense ? 24 : (profile.isDense ? 27 : 30)
        }
        let expressiveWidth = (profile.isCompact ? 146.0 : (profile.isDense ? 126 : 136)) + jitter(hash, 5, 32)
        let balancedWidth = (profile.isVeryDense ? 104.0 : (profile.isDense ? 114 : 124)) + jitter(hash, 7, 24)
        let compactWidth = (profile.longestWord >= 14 ? 84.0 : (profile.isVeryDense ? 90 : 98)) + jitter(hash, 11, 18)
        let heavy = 650 + Int(jitter(hash, 13, 180).rounded())
        let medium = 610 + Int(jitter(hash, 17, 150).rounded())
        let compact = 580 + Int(jitter(hash, 19, 120).rounded())
        let slantExpressive = slant(hash, 23, [0, -4, -8, -12])
        let slantBalanced = slant(hash, 29, [0, -3, -6, -9])
        let slantCompact = slant(hash, 31, [0, -2, -4, -6])

        func style(_ size: Double, _ weight: Int, _ width: Double, _ slant: Double) -> Style {
            Style(size: CGFloat(size), weight: weight, width: CGFloat(width), slant: CGFloat(slant))
        }
        return [
            style(base + (profile.isCompact ? 1.5 : 0.5), clamp(heavy, 560, 820), clamp(expressiveWidth, 102, 166),
                  slantExpressive),
            style(base, clamp(medium, 540, 780), clamp(balancedWidth + 10, 96, 152), slantExpressive),
            style(base - 0.5, clamp(heavy, 560, 820), clamp(balancedWidth, 92, 144), slantBalanced),
            style(base - 1.5, clamp(medium, 540, 780), clamp(balancedWidth - 10, 88, 136), slantBalanced),
            style(base - 2.5, clamp(compact, 520, 740), clamp(compactWidth, 78, 120), slantCompact),
            style(base - 4, clamp(compact - 30, 500, 700), clamp(compactWidth - 12, 72, 108), slantCompact),
        ]
    }
}
