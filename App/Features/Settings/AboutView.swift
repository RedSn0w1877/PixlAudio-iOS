import SwiftUI

/// About (Android `AboutScreen`): the collapsing "About" header (170 dp), the hero card (app icon circle, name,
/// tagline, the version capsule — long-press opens the easter egg — and the three signal chips), the app-update
/// card, "Maintainer" with the maintainer card, and "Licenses and notices" with the open-source licences row. Cards
/// are glass; the small chips inside them are fills.
struct AboutView: View {
    var screenID = "about"

    @Environment(Router.self) private var router
    @State private var appeared = false

    var body: some View {
        SettingsScaffold(title: L10n.aboutScreenTitle, screenID: screenID, expandedHeight: 118, spacing: 0) {
            AboutHeroCard { router.push(.easterEgg) }
                .padding(.top, 8)
            AppUpdateCard()
                .padding(.top, 12)
            AboutSectionHeader(title: L10n.aboutMaintainerTitle, subtitle: L10n.aboutMaintainerSubtitle)
                .padding(.top, 24)
            AboutMaintainerCard()
            AboutSectionHeader(title: L10n.aboutLicensesTitle, subtitle: L10n.aboutLicensesSubtitle)
                .padding(.top, 24)
            AboutLinkRow(title: L10n.aboutOpenSourceLicenses, subtitle: L10n.aboutOpenSourceLicensesSubtitle,
                         systemImage: "building.columns.fill", identifier: "about.licenses") {
                router.push(.openSourceLicenses)
            }
            Spacer().frame(height: 24)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 40)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
    }
}

/// Android `AboutHeroCard`: 30 pt corners, `surfaceContainerLow`.
private struct AboutHeroCard: View {
    let onVersionLongPress: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var longPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 48, height: 48)
                    .background(theme.primaryContainer, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.aboutAppName)
                        .pixlFont(.headlineSmall, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(L10n.aboutTagline)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(height: 12)
            Text(L10n.aboutVersionFormat(AppUpdateChecker.installedVersion))
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.onTertiaryContainer)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.tertiaryContainer, in: Capsule())
                .contentShape(Capsule())
                .onLongPressGesture {
                    longPressed.toggle()
                    onVersionLongPress()
                }
                .sensoryFeedback(.impact(weight: .heavy), trigger: longPressed)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(L10n.brickTitle)) { onVersionLongPress() }
                .accessibilityIdentifier("about.version")
            Spacer().frame(height: 12)
            FlowChips(spacing: 6) {
                signal(L10n.aboutSignalOpenSource, "globe")
                signal(L10n.aboutSignalCommunityFirst, "sparkles")
                signal(L10n.aboutSignalMaterial3, "paintpalette")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .accessibilityIdentifier("about.hero")
    }

    private func signal(_ label: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
            Text(label)
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfaceContainerHigh.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A wrapping row of chips (Android `FlowRow`).
struct FlowChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Android `AboutSectionHeader`: `titleLarge` bold over `bodyMedium`, 16 pt in, 8 pt vertical padding.
private struct AboutSectionHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// Android `ContributorCard` for the core maintainer (22 pt corners, 48 pt avatar circle).
private struct AboutMaintainerCard: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "memorychip")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 48, height: 48)
                .background(theme.surfaceContainerHighest, in: Circle())
                .accessibilityLabel(L10n.aboutCdContributorIcon("RedSn0w Studios"))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "RedSn0w Studios")
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(String(localized: "about_maintainer_role", defaultValue: "Developed & maintained by Hoa Vo"))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .padding(.top, 1)
                Text(String(localized: "about_maintainer_detail",
                            defaultValue: "Carrying PixlAudio forward, one release at a time."))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .padding(12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainer.opacity(SettingsTint.row))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about.maintainer")
    }
}

/// Android `OpenSourceLicensesCard`: 22 pt corners, the icon in a `secondaryContainer` circle, chevron.
private struct AboutLinkRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 42, height: 42)
                    .background(theme.secondaryContainer, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).pixlFont(.titleMedium, weight: .semibold).foregroundStyle(theme.onSurface)
                    Text(subtitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainer.opacity(SettingsTint.row), interactive: true)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - App updates (Android `AppUpdateCard`)

/// Android `AppUpdateCard`: checks GitHub for a newer release once per visit. iOS can't install itself (the app is
/// sideloaded), so an available update links to the release page with a note instead of "Download & install".
private struct AppUpdateCard: View {
    @State private var checker = AppUpdateChecker()
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = checker.state
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.update != nil ? theme.onPrimaryContainer : theme.onSecondaryContainer)
                    .frame(width: 42, height: 42)
                    .background(state.update != nil ? theme.primaryContainer : theme.secondaryContainer, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.appUpdateTitle)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                    Text(status(state))
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(state.isFailure ? theme.error : theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let update = state.update {
                if !update.notes.isEmpty {
                    Text(update.notes)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(8)
                }
                Text(String(localized: "app_update_sideload_note",
                            defaultValue: "Install the new version with Sideloadly from the release page."))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.tertiary)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let update = state.update, let url = URL(string: update.releaseURL) {
                    Button(L10n.appUpdateActionReleasePage) { openURL(url) }
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.primary)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                }
                if case .checking = state {
                    SettingsFillButton(title: L10n.appUpdateActionChecking, style: .tonal, enabled: false,
                                       fullWidth: false) {}
                } else if state.update == nil {
                    SettingsFillButton(title: L10n.appUpdateActionCheck, style: .tonal, fullWidth: false) {
                        Task { await checker.check() }
                    }
                    .accessibilityIdentifier("about.checkUpdates")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainer.opacity(SettingsTint.row))
        .task {
            // One call per visit (GitHub's anonymous limit is 60 an hour); never in UI tests (no network).
            if case .idle = checker.state, !LaunchConfiguration.current.isUITest { await checker.check() }
        }
    }

    private func status(_ state: AppUpdateChecker.State) -> String {
        switch state {
        case .idle: L10n.appUpdateStatusCurrent(AppUpdateChecker.installedVersion)
        case .checking: L10n.appUpdateStatusChecking
        case .upToDate: L10n.appUpdateStatusUpToDate(AppUpdateChecker.installedVersion)
        case .available(let update): update.version
        case .failed(let message): message
        }
    }
}

@Observable
final class AppUpdateChecker {
    nonisolated struct Release: Sendable, Equatable {
        let version: String
        let releaseURL: String
        let notes: String
    }

    nonisolated enum State: Sendable, Equatable {
        case idle, checking, upToDate
        case available(Release)
        case failed(String)

        var update: Release? { if case .available(let r) = self { r } else { nil } }
        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    private(set) var state: State = .idle

    static let installedVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/RedSn0w1877/PixlAudio-iOS/releases/latest")

    func check() async {
        guard let url = Self.latestReleaseURL else { return }
        state = .checking
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { state = .upToDate; return }
            guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(latest, than: Self.installedVersion) {
                let ipaSize = release.assets?.first { $0.name.hasSuffix(".ipa") }?.size
                let size = ipaSize.map { ByteFormat.short(Int64($0)) } ?? "GitHub"
                state = .available(Release(version: L10n.appUpdateStatusAvailable(latest, size),
                                           releaseURL: release.htmlURL, notes: release.body ?? ""))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Dotted numeric comparison ("1.10.0" > "1.9.2").
    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let assets: [Asset]?

        nonisolated struct Asset: Decodable {
            let name: String
            let size: Int
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, assets
            case htmlURL = "html_url"
        }
    }
}
