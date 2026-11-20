import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

// The views of the search history (the rules are `SearchHistoryRules`, the state is `SearchModel`; the Android twin is
// `SearchHistoryList` in `SearchScreen.kt`):
// - `SearchRecentStrip`: one horizontal row of up to 10 tiles above the genre grid while the field is not focused;
// - `SearchRecentList`: the vertical "Recent searches" list that takes the grid's place while the field is focused and
//   blank (query rows with a clock, an arrow that fills the field without searching, an X; result rows with artwork);
// - `SearchSuggestionList`: the rows that match what is typed, above the live results (max 5);
// - `SearchPrivateHint`: the one line shown instead of all of it during a private session;
// - `SearchUndoBar`: the bar that follows a removal or Clear all.
// Liquid Glass: the rows of a list sit on ONE glass shape (never a glass layer per row); only the small X is a glass
// circle (`GlassCircleButton`). The strip is plain fills (it scrolls sideways under the grid's glass cards).

nonisolated enum SearchHistoryStrings {
    static var recent: String { String(localized: "Recent") }
    static var recentSearches: String { String(localized: "Recent searches") }
    static var clearAll: String { String(localized: "Clear all") }
    static var remove: String { String(localized: "Remove") }
    static var undo: String { String(localized: "Undo") }
    static var removed: String { String(localized: "Removed from recent searches") }
    static var cleared: String { String(localized: "Recent searches cleared") }
    static var privateHint: String { String(localized: "Private session: searches aren't saved.") }
    static var recentSearchTrait: String { String(localized: "Recent search") }
    static func undoAnnouncement(_ message: String) -> String { String(localized: "\(message). Undo is available.") }
    static func fill(_ query: String) -> String { String(localized: "Use \(query) in the search field") }
    static func removeLabel(_ query: String) -> String { String(localized: "Remove \(query) from recent searches") }

    static func kind(_ kind: SearchHistoryKind?) -> String? {
        switch kind {
        case .song: String(localized: "Song")
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .playlist: String(localized: "Playlist")
        case .query, nil: nil
        }
    }
}

extension SearchHistoryItem {
    /// What a row calls itself: the opened result's name, or the typed text.
    var shownTitle: String {
        guard openKind != nil, let title = targetTitle, !title.isEmpty else { return query }
        return title
    }

    /// True for a row that stands for an opened result (artwork and a subtitle), not just a typed search.
    var isResult: Bool { openKind != nil }
}

// MARK: - Leading art

/// The 40 pt leading mark of a row: the result's artwork (round for an artist), or the history clock.
private struct HistoryLeading: View {
    let item: SearchHistoryItem
    var size: CGFloat = 40
    @Environment(\.appTheme) private var theme

    var body: some View {
        if item.isResult {
            let source = ArtworkSource(uriString: item.imageUrl)
            if item.kind == .artist {
                if let source {
                    ArtworkView(source: source, size: size, cornerRadius: size / 2)
                } else {
                    fallback(systemImage: "person.fill", shape: Circle())
                }
            } else if let source {
                ArtworkView(source: source, size: size, cornerRadius: 10)
            } else {
                fallback(systemImage: item.kind == .song ? "music.note" : "square.stack.fill",
                         shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else {
            clock
        }
    }

    private var clock: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.surfaceContainerHigh.opacity(0.7)))
            .accessibilityHidden(true)
    }

    private func fallback<S: Shape>(systemImage: String, shape: S) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(theme.onTertiaryContainer)
            .frame(width: size, height: size)
            .background(shape.fill(theme.tertiaryContainer))
            .accessibilityHidden(true)
    }
}

// MARK: - A row

/// One history row. `onOpen` runs the row (the whole row is the button); the arrow fills the field with the text without
/// searching; the X (only when `onRemove` is given) removes it.
private struct SearchHistoryRow: View {
    let item: SearchHistoryItem
    /// The suggestion rows show the typed text with a clock, never artwork.
    var plain = false
    let onOpen: () -> Void
    let onFill: () -> Void
    var onRemove: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shown = plain ? SearchHistoryItem(query: item.query, timestamp: item.timestamp) : item
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                HistoryLeading(item: shown)
                VStack(alignment: .leading, spacing: 0) {
                    Text(shown.shownTitle)
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    if let kind = SearchHistoryStrings.kind(shown.kind) {
                        Text(kind)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)

            Button(action: onFill) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(SearchHistoryStrings.fill(item.query))
            .accessibilityIdentifier("search.history.fill")

            if let onRemove {
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(SearchHistoryStrings.removeLabel(item.query)),
                                  size: 32, iconSize: 13, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                  foreground: theme.onSurfaceVariant, action: onRemove)
                    .accessibilityIdentifier("search.history.remove")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
    }
}

/// The one glass shape the rows of a list sit on (never a glass layer per row).
private struct HistoryRowsContainer<Content: View>: View {
    let content: Content
    @Environment(\.appTheme) private var theme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: 0) { content }
            .padding(.vertical, 4)
            .pixlGlass(in: RoundedRectangle(cornerRadius: SearchMetrics.resultCardRadius, style: .continuous),
                       tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
    }
}

// MARK: - Focused and blank: the vertical list

struct SearchRecentList: View {
    let items: [SearchHistoryItem]
    let onOpen: (SearchHistoryItem) -> Void
    let onFill: (SearchHistoryItem) -> Void
    let onRemove: (SearchHistoryItem) -> Void
    let onClearAll: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(SearchHistoryStrings.recentSearches)
                        .pixlFont(.titleLarge, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button(action: onClearAll) {
                        Text(SearchHistoryStrings.clearAll)
                            .pixlFont(.labelLarge, weight: .bold)
                            .foregroundStyle(theme.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                    .accessibilityIdentifier("search.history.clearAll")
                }
                .padding(.leading, 6)
                HistoryRowsContainer {
                    ForEach(items, id: \.key) { item in
                        SearchHistoryRow(item: item, onOpen: { onOpen(item) }, onFill: { onFill(item) },
                                         onRemove: { onRemove(item) })
                            .contextMenu {
                                Button(role: .destructive) { onRemove(item) } label: {
                                    Label(SearchHistoryStrings.remove, systemImage: "xmark")
                                }
                            }
                    }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
        .padding(.horizontal, 18)
        .clipShape(TopRoundedClip(radius: 24))
        .accessibilityIdentifier("search.recentList")
    }
}

// MARK: - Typing: the rows that match

/// The history rows that match what is typed (max 5), a block at the top of the results.
struct SearchSuggestionList: View {
    let items: [SearchHistoryItem]
    let onOpen: (SearchHistoryItem) -> Void
    let onFill: (SearchHistoryItem) -> Void

    var body: some View {
        if !items.isEmpty {
            HistoryRowsContainer {
                ForEach(items, id: \.key) { item in
                    SearchHistoryRow(item: item, plain: true, onOpen: { onOpen(item) }, onFill: { onFill(item) })
                }
            }
            .padding(.bottom, SearchMetrics.rowSpacing)
            .accessibilityIdentifier("search.suggestions")
        }
    }
}

// MARK: - Not focused: the strip above the grid

struct SearchRecentStrip: View {
    let items: [SearchHistoryItem]
    let onOpen: (SearchHistoryItem) -> Void
    let onRemove: (SearchHistoryItem) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SearchHistoryStrings.recent)
                .pixlFont(.titleLarge, weight: .semibold)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 6)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.key) { item in
                        SearchRecentTile(item: item, onOpen: { onOpen(item) }, onRemove: { onRemove(item) })
                            .contextMenu {
                                Button(role: .destructive) { onRemove(item) } label: {
                                    Label(SearchHistoryStrings.remove, systemImage: "xmark")
                                }
                            }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 14)
        .accessibilityIdentifier("search.recentStrip")
    }
}

private struct SearchRecentTile: View {
    let item: SearchHistoryItem
    let onOpen: () -> Void
    let onRemove: () -> Void
    @Environment(\.appTheme) private var theme

    private static let artSize: CGFloat = 64

    var body: some View {
        Button(action: onOpen) {
            if item.isResult {
                VStack(spacing: 6) {
                    HistoryLeading(item: item, size: Self.artSize)
                    Text(item.shownTitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .frame(width: Self.artSize + 8)
                }
            } else {
                // A typed search: a chip, centred on the art row's height.
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Text(item.query)
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(theme.surfaceContainerHigh.opacity(0.85)))
                .padding(.top, (Self.artSize - 40) / 2)
            }
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.shownTitle, SearchHistoryStrings.kind(item.kind), SearchHistoryStrings.recentSearchTrait]
            .compactMap { $0 }.joined(separator: ", "))
        // The long-press menu is not reachable with VoiceOver: removal is also an action on the tile.
        .accessibilityAction(named: Text(SearchHistoryStrings.remove), onRemove)
        .accessibilityIdentifier("search.recentTile")
    }
}

// MARK: - Private session

struct SearchPrivateHint: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
            Text(SearchHistoryStrings.privateHint)
                .pixlFont(.bodyMedium)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.leading, 6)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.privateHint")
    }
}

// MARK: - Undo

/// The bar after a removal or Clear all: what happened and Undo, on one inverse glass capsule (its button is plain text,
/// no glass on glass).
struct SearchUndoBar: View {
    let undo: SearchHistoryUndo
    let onUndo: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(undo.message)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.inverseOnSurface)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onUndo) {
                Text(SearchHistoryStrings.undo)
                    .pixlFont(.labelLarge, weight: .bold)
                    .foregroundStyle(theme.inversePrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
            .accessibilityIdentifier("search.undo")
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .pixlGlass(in: Capsule(), tint: theme.inverseSurface.opacity(GlassTint.prominent))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.undoBar")
    }
}
