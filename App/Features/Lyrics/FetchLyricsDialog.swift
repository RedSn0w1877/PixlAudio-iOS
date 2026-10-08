import PixlLyrics
import PixlModel
import SwiftUI

/// The "find lyrics" dialog (Android `FetchLyricsDialog`): ask → searching → pick a result / not found (manual title
/// and artist) / error. A centred glass card (32 pt corners) over a dim backdrop. Since 2026-10-07 (Hoa: the lyrics page
/// had "0 liquid glass") the card is tinted 45 % rather than 62 % and the backdrop dims 35 % rather than 45 %, so the
/// animated artwork reads through; the fields and result rows inside stay fills (no glass on glass).
struct FetchLyricsDialog: View {
    let state: LyricsController.SearchState
    let song: Song?
    let onSearch: (_ forcePick: Bool) -> Void
    let onPick: (LyricsSearchResult) -> Void
    let onManualSearch: (_ title: String, _ artist: String?) -> Void
    let onImport: () -> Void
    let onDismiss: () -> Void

    @Environment(\.playerTheme) private var theme
    @State private var forcePick = false
    @State private var title = ""
    @State private var artist = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                switch state {
                case .idle, .success: idle
                case .loading: loading
                case .pickResult(let results): pick(results)
                case .notFound: notFound
                case .error(let message): error(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .glassEffect(Glass.regular.tint(theme.surfaceContainerHigh.opacity(0.45)),
                         in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(24)
        }
        .onAppear {
            title = song?.title ?? ""
            let a = song?.displayArtist ?? ""
            artist = a.lowercased() == "<unknown>" ? "" : a
        }
        // A modal dialog for VoiceOver (the lyrics behind stay out of reach); escape cancels it.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
        .accessibilityIdentifier("dialog.fetchLyrics")
    }

    // MARK: States

    private var idle: some View {
        VStack(spacing: 0) {
            icon("music.note", fill: theme.secondaryContainer, foreground: theme.onSecondaryContainer, size: 40, radius: 24)
            Spacer().frame(height: 20)
            if let song {
                Text(song.title)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(song.displayArtist)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.primary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Lyrics not found")
                    .pixlFont(.headlineSmall)
                    .foregroundStyle(theme.onSurface)
            }
            Spacer().frame(height: 12)
            Text("Would you like to search for lyrics online?")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 32)
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Show lyric options")
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSecondaryContainer)
                    Text("Always open the picker instead of auto-applying the first match")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSecondaryContainer.opacity(0.75))
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $forcePick)
                    .labelsHidden()
                    .tint(theme.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.secondaryContainer.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer().frame(height: 16)
            VStack(spacing: 12) {
                actionButton("Search", systemImage: "magnifyingglass", fill: theme.primary, foreground: theme.onPrimary,
                             radius: 26) { onSearch(forcePick) }
                actionButton("Import", systemImage: "icloud.and.arrow.up", fill: theme.secondary,
                             foreground: theme.onSecondary, radius: 12, action: onImport)
                textButton("Cancel", action: onDismiss)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.primary)
            Text("Searching for lyrics…")
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
        }
        .padding(.vertical, 48)
    }

    /// The catalogs behind the results, in order of first appearance.
    private static func providers(of results: [LyricsSearchResult]) -> [String] {
        var seen: [String] = []
        for result in results where !seen.contains(result.source) { seen.append(result.source) }
        return seen
    }

    private func pick(_ results: [LyricsSearchResult]) -> some View {
        VStack(spacing: 0) {
            Text("Found \(results.count) match(es)")
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 24)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(results, id: \.record.id) { result in
                        resultCard(result)
                    }
                    // One credit per catalog that contributed a result (BiniLyrics, LRCLIB).
                    VStack(spacing: 2) {
                        ForEach(Self.providers(of: results), id: \.self) { source in
                            Text("Lyrics provided by \(source)")
                                .pixlFont(.bodySmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxHeight: 350)
            Spacer().frame(height: 16)
            textButton("Cancel", action: onDismiss)
        }
    }

    private func resultCard(_ result: LyricsSearchResult) -> some View {
        let synced = !(result.record.syncedLyrics ?? "").isEmpty
        return Button { onPick(result) } label: {
            HStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(synced ? theme.onPrimaryContainer : theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .background(synced ? theme.primaryContainer : theme.surfaceVariant, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(result.record.name)
                            .pixlFont(.titleMedium, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                        if synced {
                            Text("SYNCED")
                                .pixlFont(.labelSmall, weight: .bold)
                                .foregroundStyle(theme.onPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.primary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    Text(verbatim: "\(result.record.artistName) • \(result.record.albumName)")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(theme.surfaceContainerHighest.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
    }

    private var notFound: some View {
        VStack(spacing: 0) {
            icon("magnifyingglass", fill: theme.secondaryContainer, foreground: theme.onSecondaryContainer, size: 36, radius: 20)
            Spacer().frame(height: 16)
            Text("Lyrics not found")
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.onSurface)
            Spacer().frame(height: 12)
            Text("We couldn't find lyrics automatically. You can edit the title or artist and try searching manually.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 16)
            field("Song Title", text: $title)
            Spacer().frame(height: 8)
            field("Artist (optional)", text: $artist)
            Spacer().frame(height: 24)
            VStack(spacing: 12) {
                actionButton("Search", systemImage: "magnifyingglass", fill: theme.primary, foreground: theme.onPrimary,
                             radius: 18) {
                    let a = artist.trimmingCharacters(in: .whitespaces)
                    onManualSearch(title, a.isEmpty ? nil : a)
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                textButton("Cancel", action: onDismiss)
            }
        }
    }

    private func error(_ message: String) -> some View {
        VStack(spacing: 0) {
            icon("exclamationmark.circle", fill: theme.errorContainer, foreground: theme.onErrorContainer, size: 36, radius: 20)
            Spacer().frame(height: 24)
            Text("Error")
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.error)
            Spacer().frame(height: 8)
            Text(verbatim: message)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 32)
            actionButton("OK", systemImage: nil, fill: theme.error, foreground: theme.onError, radius: 18,
                         action: onDismiss)
        }
    }

    // MARK: Pieces

    private func icon(_ systemImage: String, fill: Color, foreground: Color, size: CGFloat, radius: CGFloat) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.8, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 72, height: 72)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.primary)
            TextField(label, text: text)
                .pixlFont(.bodyLarge)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.outline, lineWidth: 1))
        }
    }

    private func actionButton(_ title: LocalizedStringKey, systemImage: String?, fill: Color, foreground: Color,
                              radius: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                }
                Text(title).pixlFont(.labelLarge)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            // A fill on the glass card (no glass on glass).
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
    }

    private func textButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
    }
}
