import SwiftUI

/// "Paste the lyrics" (Android `SyncWordsEntryScreen`, spec §2.3): title, hint, a big text field (24 pt corners, white
/// 8 % with a 16 % rim — a clear glass panel here), then Find lyrics online · Next.
struct SyncWordsEntryScreen: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    @State private var text: String
    @State private var confirmTooLong = false
    @FocusState private var focused: Bool

    static let maxLines = 400
    static let maxWords = 5_000

    init(session: LyricsSyncSession, palette: SyncEditorPalette) {
        self.session = session
        self.palette = palette
        _text = State(initialValue: session.wordsSeed)
    }

    private var hasWords: Bool { text.split(whereSeparator: \.isNewline).contains { !$0.allSatisfy(\.isWhitespace) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SyncTopBar(title: session.title, palette: palette, onClose: session.requestClose)
            Text(SyncStrings.pasteTitle)
                .pixlFont(.custom(size: 30, weight: .bold, lineHeight: 36))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text(SyncStrings.pasteBody)
                .pixlFont(.custom(size: 16))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 16)
            field
            HStack(spacing: 10) {
                EditorButton(palette: palette, enabled: !session.searching, fillWidth: true,
                             action: session.findLyricsOnline) { color in
                    if session.searching {
                        ProgressView().controlSize(.small).tint(color).frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    Spacer().frame(width: 8)
                    EditorButtonText(text: SyncStrings.findOnline, color: color, bold: false)
                }
                EditorButton(palette: palette, prominent: true, enabled: hasWords, fillWidth: true, action: next) { color in
                    EditorButtonText(text: SyncStrings.next, color: color)
                }
                .accessibilityIdentifier("sync.words.next")
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        .overlay {
            if let hits = session.searchHits {
                SyncDialogCard(title: SyncStrings.pickResult, dismissTitle: SyncStrings.cancel,
                               onDismiss: session.clearSearchHits) {
                    if hits.isEmpty {
                        Text(SyncStrings.noResults)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                                    hitRow(hit)
                                }
                            }
                        }
                        .frame(maxHeight: 420)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.searchHits == nil)
        .alert(SyncStrings.tooLong, isPresented: $confirmTooLong) {
            Button(SyncStrings.useAnyway) { session.submitWords(text) }
            Button(SyncStrings.edit, role: .cancel) {}
        }
        .accessibilityIdentifier("sync.words")
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(SyncStrings.pasteBody)
                    .pixlFont(.custom(size: 18, lineHeight: 26))
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 18))
                .lineSpacing(8)
                .foregroundStyle(.white)
                .tint(palette.accent)
                .scrollContentBackground(.hidden)
                .focused($focused)
                // TextEditor insets its text by ~5 pt; pull it back so it lines up with the placeholder.
                .padding(.horizontal, -5)
                .padding(.top, -8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(palette.chipGlass(interactive: false), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { focused = true }
    }

    private func hitRow(_ hit: SyncSearchHit) -> some View {
        Button {
            text = hit.text
            session.clearSearchHits()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.label)
                    .pixlFont(.custom(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(hit.text.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " / "))
                    .pixlFont(.custom(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
    }

    private func next() {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let words = lines.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        if lines.count > Self.maxLines || words > Self.maxWords {
            confirmTooLong = true
        } else {
            session.submitWords(text)
        }
    }
}
