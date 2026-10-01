import PixlModel
import SwiftUI

/// Taizo — TAIS Engine 3's chat (Android `TaisChatSheet`): the gradient avatar with "Taizo / Your on-device AI DJ",
/// the empty state (big avatar, welcome text, suggestion chips) or the conversation, and the prompt field with the
/// send button. A play/queue/find prompt answers with song rows (tap one to play it) plus Play Queue / Add to Queue;
/// anything else is answered by the configured AI provider. Bubbles and chips are glass in Android's shapes; the
/// buttons and rows inside a bubble are fills (no glass on glass).
struct TaisChatSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    private var model: TaisChatModel { env.ai.chat }

    /// Android caps the sheet's column at 620 dp; with the handle and insets the system sheet is this tall.
    static let sheetHeight: CGFloat = 680
    /// The UI tests' scripted conversation (`-screen taisChatConversation`): a genre request answered from the
    /// demo library with the AI intro line, then a music question answered by the scripted provider.
    static let demoScript = ["Play some indie songs", "Who produced Random Access Memories?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer().frame(height: 12)
            if model.messages.isEmpty {
                TaizoEmptyState { suggestion in
                    model.send("Play some \(suggestion) songs")
                }
                .frame(maxHeight: .infinity)
            } else {
                messageList
            }
            Spacer().frame(height: 10)
            inputRow
            Spacer().frame(height: 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            guard env.launch.screen == .taisChatConversation, model.messages.isEmpty else { return }
            await model.runScript(Self.demoScript)
        }
        .accessibilityIdentifier("screen.taisChat")
    }

    private var header: some View {
        HStack(spacing: 12) {
            TaizoAvatar(size: 40, iconSize: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Taizo")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Text("Your on-device AI DJ")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        TaisChatMessageRow(message: message, isResolvingOnlineTracks: model.isResolvingOnlineTracks,
                                           onPlay: { songs in
                                               model.play(songs)
                                               dismiss()
                                           },
                                           onQueue: { model.queue($0) },
                                           onResolve: { items, source, play in
                                               model.resolveOnlineTracks(items, source: source, thenPlay: play) { dismiss() }
                                           })
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation(PixlMotion.state) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The 28 pt outlined field (primary outline when focused) and the filled send button.
    private var inputRow: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 8) {
                TextField("", text: Bindable(model).inputText,
                          prompt: Text("Ask Taizo anything, or a mood/genre to play…").foregroundStyle(theme.onSurfaceVariant))
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                    .tint(theme.primary)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { model.sendPrompt() }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(inputFocused ? theme.primary : theme.outlineVariant, lineWidth: inputFocused ? 2 : 1))
                    .accessibilityIdentifier("taisChat.input")
                GlassCircleButton(systemImage: "paperplane.fill", accessibilityLabel: "Send", size: 40, iconSize: 18,
                                  tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary) {
                    model.sendPrompt()
                }
                .accessibilityIdentifier("taisChat.send")
            }
        }
    }
}

/// The gradient avatar (`primary` → `tertiary`, white sparkles). Not a Material surface — Taizo's mark.
struct TaizoAvatar: View {
    let size: CGFloat
    let iconSize: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [theme.primary, theme.tertiary], startPoint: .topLeading,
                                       endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Fills the sheet before the first prompt: a big avatar, a welcome line and tappable suggestions.
struct TaizoEmptyState: View {
    let onSuggestion: (String) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TaizoAvatar(size: 72, iconSize: 30)
            Spacer().frame(height: 16)
            Text("Hey, I'm Taizo")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Spacer().frame(height: 6)
            Text("Tell me a mood or genre and I'll build you a queue, or just ask me anything about music — an artist, a song, recommendations, whatever's on your mind.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer().frame(height: 24)
            GlassEffectContainer(spacing: 4) {
                AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(TaisChatModel.suggestions, id: \.self) { suggestion in
                        GlassPillButton(title: LocalizedStringKey(suggestion),
                                        tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                        foreground: theme.onSurfaceVariant, style: .labelLarge,
                                        horizontalPadding: 16, verticalPadding: 8) {
                            onSuggestion(suggestion)
                        }
                        .accessibilityIdentifier("taisChat.suggestion.\(suggestion)")
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One chat row (Android `TaisChatMessageRow`).
struct TaisChatMessageRow: View {
    let message: TaisChatMessage
    let isResolvingOnlineTracks: Bool
    let onPlay: ([Song]) -> Void
    let onQueue: ([Song]) -> Void
    let onResolve: ([SearchResultItem], SearchSource, Bool) -> Void

    @Environment(\.appTheme) private var theme

    /// Taizo's bubbles: a 4 pt top-leading corner, 20 elsewhere; the user's: a 4 pt bottom-trailing corner.
    private static let taizoShape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 20,
                                                           bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
    private static let userShape = UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                          bottomTrailingRadius: 4, topTrailingRadius: 20, style: .continuous)

    var body: some View {
        switch message {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 0)
                Text(text)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .pixlGlass(in: Self.userShape, tint: theme.primary.opacity(GlassTint.prominent))
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        case .thinking:
            HStack(spacing: 8) {
                TaizoAvatar(size: 28, iconSize: 13)
                ThinkingDots(color: theme.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .pixlGlass(in: Self.taizoShape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
                Spacer(minLength: 0)
            }
            .accessibilityLabel("Taizo is thinking")
        case .textReply(_, let text, let isError):
            HStack(alignment: .top, spacing: 8) {
                TaizoAvatar(size: 28, iconSize: 13)
                Text(text)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(isError ? theme.onErrorContainer : theme.onSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .pixlGlass(in: Self.taizoShape,
                               tint: isError ? theme.errorContainer.opacity(GlassTint.container)
                                             : theme.surfaceContainerHigh.opacity(GlassTint.surface))
                    .frame(maxWidth: 300, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .djReply(_, _, let result, let intro):
            HStack(alignment: .top, spacing: 8) {
                TaizoAvatar(size: 28, iconSize: 13)
                djContent(result: result, intro: intro)
                    .padding(14)
                    .pixlGlass(in: Self.taizoShape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func djContent(result: DjRouteResult, intro: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch result {
            case .offline(let songs):
                Text(intro ?? "Found \(songs.count) songs in your library.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer().frame(height: 10)
                bulkButtons(enabled: true, play: { onPlay(songs) }, queue: { onQueue(songs) })
                Spacer().frame(height: 10)
                VStack(spacing: 4) {
                    ForEach(songs.prefix(8)) { song in
                        TaizoTrackRow(title: song.title, subtitle: song.displayArtist,
                                      artwork: ArtworkSource(song: song), enabled: true) {
                            onPlay([song])
                        }
                    }
                }
            case .online(let items, let source):
                Text(intro ?? "Found \(items.count) tracks on \(source == .spotify ? "Spotify" : "YouTube Music").")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer().frame(height: 10)
                bulkButtons(enabled: !isResolvingOnlineTracks, play: { onResolve(items, source, true) },
                            queue: { onResolve(items, source, false) })
                Spacer().frame(height: 10)
                VStack(spacing: 4) {
                    ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { _, item in
                        let info = Self.trackInfo(item)
                        TaizoTrackRow(title: info.title, subtitle: info.artist, artwork: ArtworkSource(uriString: info.art),
                                      enabled: !isResolvingOnlineTracks) {
                            onResolve([item], source, true)
                        }
                    }
                }
            case .noResults:
                Text("Couldn't find anything for that — try a different genre or mood.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
            }
        }
    }

    /// Two `FilledTonalButton`s (20 pt corners, 18 pt icons): fills on the bubble's glass.
    private func bulkButtons(enabled: Bool, play: @escaping () -> Void, queue: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            tonalButton("Play Queue", systemImage: "play.fill", enabled: enabled, action: play)
            tonalButton("Add to Queue", systemImage: "text.badge.plus", enabled: enabled, action: queue)
        }
    }

    private func tonalButton(_ title: LocalizedStringKey, systemImage: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                Text(title).pixlFont(.labelLarge).lineLimit(1)
            }
            .foregroundStyle(theme.onSecondaryContainer)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(theme.secondaryContainer.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private static func trackInfo(_ item: SearchResultItem) -> (title: String, artist: String, art: String?) {
        switch item {
        case .catalog(let track): (track.title, track.artist, track.albumArtUrl)
        case .youtubeMusic(let track): (track.title, track.artist, track.thumbnailUrl)
        case .song(let song): (song.title, song.displayArtist, song.albumArtUriString)
        case .album(let album): (album.title, album.artist, album.albumArtUriString)
        case .artist(let artist): (artist.name, "", nil)
        case .playlist(let playlist): (playlist.name, "", nil)
        }
    }
}

/// One result row (Android `TaizoSongRow` / `TaizoOnlineTrackRow`): 44 pt art (8 pt corners), title / artist,
/// a play icon; tap anywhere to play it.
struct TaizoTrackRow: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    let enabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ArtworkView(source: artwork, size: 44, cornerRadius: 8)
                Spacer().frame(width: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .pixlFont(.bodyMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .accessibilityLabel("Play \(title)")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!enabled)
    }
}

/// Three dots pulsing out of phase (900 ms, linear; alpha 0.3 + 0.7·sin) — Taizo's typing indicator. Ticks only
/// while a prompt is in flight (the row exists only then).
struct ThinkingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let local = (phase + Double(index) * 0.33).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .fill(color.opacity(0.3 + 0.7 * min(max(sin(local * .pi), 0), 1)))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Compose `FlowRow` for the suggestion chips: rows of chips, start-aligned, wrapped at the proposed width.
nonisolated struct AIFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, extra > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
