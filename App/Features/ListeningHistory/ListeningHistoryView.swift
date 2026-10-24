import PixlLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Library & storage › Listening history (spec B2): where the imported history stands, step-by-step help for
/// the two data downloads (with buttons that open the right pages), and the file picker for the ZIP or its JSON files.
/// Glass rows from the settings design system; the buttons on a row are fills.
struct ListeningHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var showsPicker = false

    private var store: ImportedHistoryStore { env.importedHistory }

    static let spotifyPrivacyURL = URL(string: "https://www.spotify.com/account/privacy/")!
    static let takeoutURL = URL(string: "https://takeout.google.com/")!

    var body: some View {
        SettingsScaffold(title: "Listening history", screenID: "listeningHistory") {
            SettingsSubsection(title: "Your imported listening") {
                ListeningHistoryStatusRow()
            }
            SettingsSubsection(title: "Spotify (counts the most)") {
                stepsRow(steps: [
                    "Open your Spotify account's Privacy page.",
                    "Under \u{201C}Download your data\u{201D}, tick Extended streaming history and request it.",
                    "Spotify emails you a download link, usually within a few days.",
                    "Download the ZIP on this phone, then tap Choose file below and pick it.",
                ], button: "Open Spotify privacy settings", identifier: "history.openSpotify") {
                    openURL(Self.spotifyPrivacyURL)
                }
            }
            SettingsSubsection(title: "YouTube Music") {
                stepsRow(steps: [
                    "Open Google Takeout and tap Deselect all.",
                    "Select only \u{201C}YouTube and YouTube Music\u{201D}.",
                    "In its options keep only history, and set the history format to JSON.",
                    "Create the export, download the ZIP on this phone, then choose it below.",
                ], button: "Open Google Takeout", identifier: "history.openTakeout") {
                    openURL(Self.takeoutURL)
                }
            }
            SettingsSubsection(title: "Import", addBottomSpace: false) {
                importRow
            }
        }
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.zip, .json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
        .task { await store.ensureLoaded() }
    }

    private func stepsRow(steps: [String], button: String, identifier: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .pixlFont(.labelLarge, weight: .bold)
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 24, height: 24)
                        .background(theme.primaryContainer, in: Circle())
                        .accessibilityHidden(true)
                    Text(step)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SettingsFillButton(title: button, systemImage: "arrow.up.right.square", style: .outlined, action: action)
                .accessibilityIdentifier(identifier)
                .padding(.top, 4)
        }
        .padding(16)
        .settingsRowGlass()
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the ZIP you downloaded, or the JSON files inside it. Everything stays on this phone, and importing the same file again never counts a play twice.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            switch store.importState {
            case .idle:
                EmptyView()
            case .reading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reading your history…")
                        .pixlFont(.bodyMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(theme.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("history.progress")
            case .done(let summary):
                resultLine(summary, systemImage: "checkmark.circle.fill", color: theme.primary)
            case .failed(let message):
                resultLine(message, systemImage: "exclamationmark.triangle.fill", color: theme.error)
            }
            SettingsFillButton(title: "Choose file", systemImage: "doc.badge.plus", style: .filled,
                               enabled: !store.isImporting) { showsPicker = true }
                .accessibilityIdentifier("history.chooseFile")
        }
        .padding(16)
        .settingsRowGlass()
    }

    private func resultLine(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .pixlFont(.bodyMedium, weight: .semibold)
                .foregroundStyle(theme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.result")
    }
}

/// "12,402 plays · 3,112 artists" / "Last synced 2 h ago" (the screen and Settings › Library & storage).
struct ListeningHistoryStatusRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        let store = env.importedHistory
        HStack(spacing: 0) {
            SettingsIcon(systemImage: "clock.arrow.circlepath")
                .padding(.trailing, 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(ListeningHistoryText.totals(plays: store.playCount, artists: store.artistCount))
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Text(ListeningHistoryText.status(store: store))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.isSyncing {
                ProgressView().controlSize(.small).tint(theme.primary)
            }
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.status")
    }
}

/// The wording shared by the screen, the settings rows and the Home card.
enum ListeningHistoryText {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func totals(plays: Int, artists: Int) -> String {
        guard plays > 0 else { return "No imported plays yet" }
        return "\(plays.formatted()) \(plays == 1 ? "play" : "plays") · \(artists.formatted()) \(artists == 1 ? "artist" : "artists")"
    }

    /// "Last synced 2 h ago · 12,402 plays", or what to do first.
    static func status(store: ImportedHistoryStore) -> String {
        var parts: [String] = []
        if store.lastSyncMs > 0 {
            let date = Date(timeIntervalSince1970: Double(store.lastSyncMs) / 1000)
            let now = Date(timeIntervalSince1970: Double(store.clock.nowMs()) / 1000)
            parts.append("Last synced \(relative.localizedString(for: date, relativeTo: now))")
        }
        if store.playCount > 0 {
            var sources: [String] = []
            if store.spotifyPlayCount > 0 { sources.append("\(store.spotifyPlayCount.formatted()) from Spotify") }
            if store.youTubePlayCount > 0 { sources.append("\(store.youTubePlayCount.formatted()) from YouTube Music") }
            parts.append(sources.joined(separator: ", "))
        }
        if parts.isEmpty { return "Connect Spotify or import your data download to make your mixes smarter." }
        return parts.joined(separator: " · ")
    }
}

/// Home's one-time card: "Make your mixes smarter: import your Spotify history" (opens Listening history; closes for
/// good with its ×). Glass tinted with the primary container; the close button is a plain fill.
struct ListeningHistoryHomeCard: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make your mixes smarter")
                            .pixlFont(.bodyLarge, weight: .semibold)
                            .foregroundStyle(theme.onPrimaryContainer)
                        Text("Import your Spotify history — years of listening, in a few taps")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onPrimaryContainer.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
            .accessibilityHint("Opens Listening history")
            .accessibilityIdentifier("home.historyCard.open")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 32, height: 32)
                    .background(theme.onPrimaryContainer.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("home.historyCard.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.primaryContainer.opacity(GlassTint.container + 0.2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.historyCard")
    }
}
