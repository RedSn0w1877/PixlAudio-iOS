import SwiftUI

/// Home's sheets (Android `BetaInfoBottomSheet`, `ChangelogBottomSheet`, `JobsBottomSheet`), presented with the system
/// sheet (`.pixlSheet()` in `SheetDestination`) with PixlAudio's layout inside.
struct HomeInfoSheet: View {
    let sheet: AppSheet

    var body: some View {
        Group {
            switch sheet {
            case .changelog: ChangelogSheetContent()
            case .jobs: JobsSheetContent()
            default: BetaInfoSheetContent()
            }
        }
        .accessibilityIdentifier("screen.\(sheet.id)")
    }
}

/// Where the iOS port's issues and history live (the Android sheets link the upstream repository).
nonisolated enum HomeProjectLinks {
    static let repository = URL(string: "https://github.com/RedSn0w1877/PixlAudio-iOS")!
    static let issues = URL(string: "https://github.com/RedSn0w1877/PixlAudio-iOS/issues")!
    static let newIssue = URL(string: "https://github.com/RedSn0w1877/PixlAudio-iOS/issues/new")!
    static let commits = URL(string: "https://github.com/RedSn0w1877/PixlAudio-iOS/commits/main")!

    /// "0.1.0" from `CFBundleShortVersionString`.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

// MARK: - Sine wave (Android HomeSineWaveLine)

/// A sine stroke under the sheet titles: 4 pt wide, 4 pt amplitude, 7.6 waves, the phase looping every 2 s like
/// Android's `animate = true` (paused with Reduce Motion). Only this small canvas redraws.
struct HomeSineWaveLine: View {
    var color: Color
    var waves: Double = 7.6
    var amplitude: CGFloat = 4
    var lineWidth: CGFloat = 4
    var period: Double = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period * 2 * .pi
            Canvas { context, size in
                guard size.width > 0 else { return }
                var path = Path()
                let samples = 200
                let mid = size.height / 2
                for i in 0..<samples {
                    let x = size.width * CGFloat(i) / CGFloat(samples - 1)
                    let theta = Double(x / size.width) * 2 * .pi * waves + phase
                    let point = CGPoint(x: x, y: mid + amplitude * CGFloat(sin(theta)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Beta sheet

private struct BetaInfoSheetContent: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let version = HomeProjectLinks.shortVersion
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    VStack(spacing: 8) {
                        Text("Beta \(version)")
                            .pixlFont(.custom(size: 36, weight: .bold))
                            .foregroundStyle(theme.onSurface)
                        HomeSineWaveLine(color: theme.tertiary.opacity(0.75 * 0.95))
                            .frame(height: 26)
                            .padding(.horizontal, 8)
                    }
                    .padding(.top, 28)

                    welcome(version: version)
                    gitHubCard

                    BetaFaqSection(title: "What to expect",
                                   summary: "What beta builds can change, break, or improve while testing.",
                                   symbol: "flame", tint: theme.primary, initiallyExpanded: true) {
                        BetaBullets([
                            "Bugs, crashes, or incomplete features may occur unexpectedly.",
                            "Some features may change or be removed without notice.",
                            "Beta builds may be more unstable than release versions.",
                            "Always check for updates before reporting a known issue.",
                        ])
                    }
                    BetaFaqSection(title: "How to report", summary: "A quick checklist before opening a new issue.",
                                   symbol: "magnifyingglass", tint: theme.secondary) {
                        BetaSubheader(symbol: "magnifyingglass", title: "Before opening an issue")
                        BetaBullets([
                            "Search existing open and closed issues to avoid duplicates.",
                            "Update to the latest PixlAudio version and confirm the problem still happens.",
                            "Restart the app and confirm the problem persists.",
                            "Try to reproduce it and write down the exact steps.",
                        ])
                        BetaDivider()
                        BetaSubheader(symbol: "checkmark.circle", title: "Which issue type?")
                        BetaBullets([
                            "Bug report: Something behaves incorrectly.",
                            "Feature request: Add a new feature or improvement.",
                            "Question: Use Discussions if enabled, or open an issue with a question label.",
                        ])
                    }
                    BetaFaqSection(title: "Bug report", summary: "Copy these fields when something behaves incorrectly or crashes.",
                                   symbol: "ladybug", tint: theme.error, container: theme.surfaceContainerHighest) {
                        BetaSubheader(symbol: "ladybug", title: "Bug Report")
                        BetaFields([
                            "Short summary:", "Expected behavior:", "Current behavior:",
                            "Steps to play/reproduce: 1. 2. 3.", "How often does it happen? Always / Sometimes / Rarely.",
                            "Screenshot / video: if available.", "Logs / stack trace: if available.",
                        ])
                        BetaDivider()
                        BetaSubheader(symbol: "info.circle", title: "Environment")
                        BetaFields([
                            "PixlAudio version:", "Install source: GitHub Release, CI build, etc.", "iOS version:",
                            "Device model:", "Extra context: special settings, permissions, etc.",
                        ])
                    }
                    BetaFaqSection(title: "Feature request", summary: "Copy these fields when you want a new feature or improvement.",
                                   symbol: "lightbulb", tint: theme.primary) {
                        BetaFields([
                            "Problem statement: What problem are you trying to solve?",
                            "Proposed solution: How should it work?",
                            "Alternatives considered: Any other approaches?",
                            "Scope: Which screens or flows are affected?",
                            "Mockup or reference image if available.",
                        ])
                    }
                    BetaFaqSection(title: "Titles, privacy, and scope", summary: "Make the report easy to triage and safe to share.",
                                   symbol: "hammer", tint: theme.tertiary, container: theme.tertiaryContainer.opacity(0.45)) {
                        BetaSubheader(symbol: "hammer", title: "Good issue titles")
                        BetaBullets([
                            "Equalizer: Indicator shifts when switching preset tabs",
                            "Search: History list does not appear for empty query",
                            "Feature: Add \"Recently Added\" playlist sort option",
                        ])
                        BetaDivider()
                        BetaSubheader(symbol: "exclamationmark.triangle", title: "Please avoid", tint: theme.error)
                        BetaBullets([
                            "Generic reports like \"It doesn't work\".",
                            "Multiple unrelated problems in one issue.",
                            "Unredacted logs or screenshots with private data.",
                        ])
                        BetaDivider()
                        BetaSubheader(symbol: "shield", title: "Privacy note")
                        Text("Before posting logs, screenshots, or videos, remove personal or private information.")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                    }
                    BetaFaqSection(title: "Nightly builds",
                                   summary: "How nightlies differ from releases, and what to include when they break.",
                                   symbol: "moon.stars", tint: theme.secondary, container: theme.primaryContainer.opacity(0.42)) {
                        BetaSubheader(symbol: "moon.stars", title: "Nightly builds")
                        Text("Nightly builds are generated from the latest commit and may contain unfinished changes, temporary bugs, or regressions. They are more experimental than official releases.")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                        Text("Access them from the repository's GitHub Actions workflow artifacts if available.")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                        BetaDivider()
                        BetaSubheader(symbol: "cloud", title: "Reporting nightly issues")
                        Text("When reporting an issue from a nightly build, always mention that it happened on a nightly build, not on the official release. Include the build date, workflow run name or number, or commit SHA if possible. Also check if the same problem happens on the latest official release.")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                    }
                    Spacer().frame(height: 104)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)

            GlassPillButton(title: "Report issue or crash", systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: theme.primaryContainer.opacity(GlassTint.prominent),
                            foreground: theme.onPrimaryContainer, horizontalPadding: 20, verticalPadding: 16) {
                openURL(HomeProjectLinks.newIssue)
            }
            .padding(24)
        }
    }

    private func welcome(version: String) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "β")
                .pixlFont(.titleMedium, weight: .black)
                .foregroundStyle(theme.onPrimary)
                .frame(width: 42, height: 42)
                .background(Circle().fill(LinearGradient(colors: [theme.primary, theme.primary.opacity(0.65)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to PixlAudio \(version)-beta")
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Text("You're using a beta build that may contain bugs, crashes, or experimental features. Help us improve by reporting issues.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    private var gitHubCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(theme.surface))
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub issue shortcut")
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSecondaryContainer)
                    Text("Search first, then open a focused report for bugs, crashes, requests, or questions.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSecondaryContainer.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 10) {
                Button { openURL(HomeProjectLinks.issues) } label: {
                    Text("Open existing issues")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceContainerHigh))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                Button { openURL(HomeProjectLinks.newIssue) } label: {
                    Text("Report issue or crash")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.primary))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
            }
        }
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                   tint: theme.secondaryContainer.opacity(0.55))
    }
}

/// Android `BetaFaqSection`: an 18 pt card that expands on tap — a 40 pt tinted icon circle, title / summary and a
/// chevron; the body in a 10 pt column.
private struct BetaFaqSection<Content: View>: View {
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    let symbol: String
    let tint: Color
    var container: Color?
    @ViewBuilder var content: Content
    @State private var expanded: Bool

    @Environment(\.appTheme) private var theme

    init(title: LocalizedStringKey, summary: LocalizedStringKey, symbol: String, tint: Color, container: Color? = nil,
         initiallyExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.tint = tint
        self.container = container
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(tint.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .pixlFont(.titleMedium, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                        Text(summary)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if expanded {
                VStack(alignment: .leading, spacing: 10) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .clipShape(shape)
        .pixlGlass(in: shape, tint: (container ?? theme.surfaceContainerHigh).opacity(GlassTint.surface + 0.1),
                   interactive: true)
    }
}

private struct BetaSubheader: View {
    let symbol: String
    let title: LocalizedStringKey
    var tint: Color?

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? theme.primary)
            Text(title)
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.onSurface)
        }
    }
}

/// Android `BetaBulletList`: 5 pt `primary` dots, `bodyMedium` in `onSurfaceVariant`, 8 pt apart.
private struct BetaBullets: View {
    let items: [LocalizedStringKey]
    @Environment(\.appTheme) private var theme

    init(_ items: [LocalizedStringKey]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(theme.primary).frame(width: 5, height: 5).padding(.top, 8)
                    Text(items[index])
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Android `BetaFieldList`: lines separated by dividers.
private struct BetaFields: View {
    let items: [LocalizedStringKey]
    @Environment(\.appTheme) private var theme

    init(_ items: [LocalizedStringKey]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 { BetaDivider() }
                Text(items[index])
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.vertical, 8)
            }
        }
    }
}

private struct BetaDivider: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        Rectangle().fill(theme.outlineVariant.opacity(0.35)).frame(height: 1)
    }
}

// MARK: - Changelog sheet

/// One version of the changelog (Android `HomeChangelogVersion`).
nonisolated struct HomeChangelogVersion: Sendable, Identifiable {
    var version: String
    var date: String
    var sections: [(title: String, items: [String])]
    var id: String { version }
}

/// The iOS port's changelog (the Android sheet lists the Android releases; the iOS app keeps the layout and lists
/// its own versions).
nonisolated enum HomeChangelog {
    static let versions: [HomeChangelogVersion] = [
        HomeChangelogVersion(version: "0.1.0-beta", date: "2026-10-01", sections: [
            ("What's New", [
                "PixlAudio on iOS: the Android app's screens rebuilt natively in Liquid Glass.",
                "Home: greeting, quick actions, mixes made for your listening, Your Mix, discovery shelves, Just added, Recently Played and your listening stats.",
                "Daily Mix and Your Mix, picked by the same recommendation engine as on Android.",
                "Listening stats for today, this week, month, year and all time.",
            ]),
            ("Improvements", [
                "Album-art colours are extracted exactly like on Android, so every song tints the app the same way.",
                "Playback history uses the Android file format, so stats carry over from a backup.",
            ]),
        ]),
    ]
}

private struct ChangelogSheetContent: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Text("Changelog")
                    .pixlFont(.custom(size: 36, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .padding(.top, 28)
                Spacer().frame(height: 16)
                HomeSineWaveLine(color: theme.primary.opacity(0.75 * 0.95))
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(HomeChangelog.versions) { version in
                            versionItem(version)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 24)

            GlassPillButton(title: "View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                            foreground: theme.onTertiaryContainer, horizontalPadding: 20, verticalPadding: 16) {
                openURL(HomeProjectLinks.commits)
            }
            .padding(24)
        }
    }

    private func versionItem(_ version: HomeChangelogVersion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(version.version)
                    .pixlFont(.labelLarge, weight: .bold)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.primaryContainer))
                Spacer()
                Text(version.date)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            VStack(spacing: 14) {
                ForEach(version.sections.indices, id: \.self) { index in
                    category(version.sections[index].title, version.sections[index].items)
                }
            }
        }
    }

    /// Android `ChangelogCategory`: a 22 pt card, `titleMedium` in `primary`, 8 pt dots, dividers between items.
    private func category(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.primary)
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(theme.primary).frame(width: 8, height: 8).padding(.top, 6)
                    Text(items[index])
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if index != items.count - 1 {
                    Rectangle().fill(theme.outlineVariant.opacity(0.35)).frame(height: 1).padding(.vertical, 10)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface + 0.1))
    }
}

// MARK: - Jobs sheet

/// Android `JobsBottomSheet`: "Active jobs", then each job with a 28 pt progress ring (or spinner / check), its label,
/// detail or "Queued", and a linear bar when the percentage is known.
private struct JobsSheetContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme

    var body: some View {
        let jobs = env.home.jobs(libraryProgress: library.lastImportProgress)
        VStack(alignment: .leading, spacing: 0) {
            Text("Active jobs")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            if jobs.isEmpty {
                Text("Nothing running right now.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.bottom, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobs) { job in row(job) }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ job: HomeJob) -> some View {
        HStack(spacing: 14) {
            Group {
                if let percent = job.percent {
                    ZStack {
                        Circle().stroke(theme.primary.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(percent) / 100)
                            .stroke(theme.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(1.5)
                } else if job.state == .running {
                    ProgressView().tint(theme.primary)
                } else {
                    Image(systemName: job.state == .queued ? "clock" : "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(job.label)
                    .pixlFont(.bodyLarge, weight: .medium)
                    .foregroundStyle(theme.onSurface)
                if let subtitle = job.detail ?? (job.state == .queued ? "Queued" : nil) {
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                if let percent = job.percent {
                    ProgressView(value: Double(percent), total: 100)
                        .tint(theme.primary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
