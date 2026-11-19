import PixlLibrary
import PixlModel
import SwiftUI

/// Settings › Developer mode › Brain data (docs/brain-spec.md, 3.7 and 12; Android `BrainDataScreen`): the genre atlas, what
/// is stored about the listener's tracks, each open-data source with its own switch, its requests today and the terms it
/// is used under, and what Spotify sent for artist genres. Read once when the screen opens; plain words, nothing animated,
/// no per-frame work. Every number is decided in PixlLibrary (`BrainDataReader`); this view only draws it.
struct BrainDataView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var model = BrainDataModel()

    var body: some View {
        SettingsScaffold(title: BrainDataStrings.title, screenID: "brainData", spacing: 12) {
            if let report = model.report {
                section(BrainDataStrings.atlasSection) {
                    if report.atlasLoaded {
                        line(BrainDataStrings.atlasVersion(report.atlasVersion, report.atlasGenres, report.atlasFamilies))
                        line(BrainDataStrings.atlasDescribed(report.atlasDescribed), dim: true)
                    } else {
                        line(BrainDataStrings.atlasMissing)
                    }
                }
                section(BrainDataStrings.knownSection) {
                    let c = report.coverage
                    if c.tracks == 0 {
                        line(BrainDataStrings.knownNone)
                    } else {
                        line(BrainDataStrings.knownTracks(c.tracks))
                        line(BrainDataStrings.knownGenre(c.withTags, BrainDataFormat.percent(c.withTags, of: c.tracks)))
                        line(BrainDataStrings.knownYear(c.withYear, BrainDataFormat.percent(c.withYear, of: c.tracks)))
                        line(BrainDataStrings.knownPopularity(c.withPopularity, BrainDataFormat.percent(c.withPopularity, of: c.tracks)))
                        line(BrainDataStrings.knownEnergy(c.withEnergy, BrainDataFormat.percent(c.withEnergy, of: c.tracks)))
                        line(BrainDataStrings.knownTempo(c.withTempo, BrainDataFormat.percent(c.withTempo, of: c.tracks)))
                        line(BrainDataStrings.knownArtists(report.artistsKnown, report.artistsWithGenres), dim: true)
                        if report.activeMisses > 0 { line(BrainDataStrings.knownMisses(report.activeMisses), dim: true) }
                    }
                }
                Text(BrainDataStrings.sourcesSection)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.primary)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(report.sources, id: \.host) { row in
                    sourceCard(row, nowMs: report.nowMs)
                }
                section(BrainDataStrings.spotifySection) {
                    if !report.spotifyShapes {
                        line(BrainDataStrings.spotifyOff)
                    } else if report.spotifyArtistSeeds == 0 {
                        line(BrainDataStrings.spotifyEmpty)
                    } else if report.spotifyArtistSeedsWithGenres == 0 {
                        line(BrainDataStrings.spotifyGenresNone(report.spotifyArtistSeeds))
                    } else {
                        line(BrainDataStrings.spotifyGenres(report.spotifyArtistSeedsWithGenres, report.spotifyArtistSeeds))
                    }
                    line(BrainDataStrings.youTubeToday(report.youTubeToday, report.youTubeLimit), dim: true)
                }
                Text(BrainDataStrings.lastRun(report))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                line(BrainDataStrings.unavailable)
            }
        }
        .task {
            if env.launch.screen == .brainData {
                model.report = BrainDataModel.demo
            } else {
                await model.refresh(env.brain)
            }
        }
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).pixlFont(.titleMedium).foregroundStyle(theme.onSurface).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: theme.surfaceContainer.opacity(SettingsTint.row))
    }

    private func line(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .pixlFont(.bodyMedium)
            .foregroundStyle(dim ? theme.onSurfaceVariant : theme.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceCard(_ row: BrainDataReport.SourceRow, nowMs: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.host.label).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(row.host.label, isOn: Binding(
                    get: { row.switchIsOn },
                    set: { model.setSourceEnabled(row.host, $0, brain: env.brain) }))
                    .labelsHidden()
                    .disabled(!row.remoteAllowed)
                    .accessibilityIdentifier("brainData.source.\(row.host.key)")
            }
            line(BrainDataStrings.sourceToday(row.requestsToday, row.host.dailyCeiling))
            line(BrainDataStrings.sourceAnswered(row.tracksAnswered), dim: true)
            line(row.lastRequestMs > 0 ? BrainDataStrings.sourceLast(BrainDataStrings.ago(nowMs: nowMs, thenMs: row.lastRequestMs))
                                       : BrainDataStrings.sourceNever, dim: true)
            if !row.remoteAllowed { line(BrainDataStrings.sourceRemoteOff) }
            Text(row.host.terms).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: theme.surfaceContainer.opacity(SettingsTint.row))
    }
}

/// The screen's state: read when it opens, again after a switch is flipped. Off the main actor; nothing at app start.
@MainActor
@Observable
final class BrainDataModel {
    var report: BrainDataReport?
    var isLoading = true

    func refresh(_ brain: BrainService) async {
        report = await brain.brainDataReport()
        isLoading = false
    }

    func setSourceEnabled(_ host: KnowledgeHost, _ enabled: Bool, brain: BrainService) {
        BrainSourceSwitch.setLocalEnabled(host, enabled)
        Task { await refresh(brain) }
    }

    /// The UI-test screen: the sources and counts of a phone a few days into using the brain.
    static var demo: BrainDataReport {
        var r = BrainDataReport()
        r.atlasLoaded = true
        r.atlasVersion = 1
        r.atlasGenres = 2249
        r.atlasFamilies = 24
        r.atlasDescribed = 612
        var c = DnaCoverage()
        c.tracks = 240; c.withTags = 191; c.withYear = 236; c.withPopularity = 208; c.withEnergy = 188; c.withTempo = 52
        r.coverage = c
        r.artistsKnown = 80
        r.artistsWithGenres = 61
        r.activeMisses = 12
        r.nowMs = 1_795_000_000_000
        r.sources = KnowledgeHost.allCases.enumerated().map { i, host in
            BrainDataReport.SourceRow(host: host, enabled: true, remoteAllowed: host != .wikidata, requestsToday: 3 + i * 7,
                                      lastRequestMs: r.nowMs - Int64(i + 1) * 900_000, tracksAnswered: 200 - i * 30)
        }
        r.youTubeToday = 21
        r.spotifyArtistSeeds = 20
        r.spotifyArtistSeedsWithGenres = 17
        r.lastRun = RefreshSchedule.Note(atMs: r.nowMs - 5 * 3_600_000, radios: 24, artists: 12, releases: 6, tracksEnriched: 48, stopped: "none")
        return r
    }
}

/// Every word of the screen (Android `strings_brain.xml`, `brain_data_*`), English, plain, sentence case. `BrainCopyTests`
/// reads this file as text: no word the app never says, and nothing that claims more than "based on what you play".
nonisolated enum BrainDataStrings {
    static var title: String { String(localized: "Brain data") }
    static var rowTitle: String { String(localized: "Brain data") }
    static var rowSubtitle: String { String(localized: "The genre atlas, what is known about your tracks and what each source was asked today") }
    static var unavailable: String { String(localized: "The music brain is off in this build") }

    static var atlasSection: String { String(localized: "Genre atlas") }
    static func atlasVersion(_ version: Int, _ genres: Int, _ families: Int) -> String {
        String(localized: "Version \(version), \(genres) genres in \(families) families")
    }
    static func atlasDescribed(_ n: Int) -> String { String(localized: "\(n) genres have a description of how they sound") }
    static var atlasMissing: String { String(localized: "The atlas could not be read") }

    static var knownSection: String { String(localized: "What is known about your tracks") }
    static var knownNone: String { String(localized: "Nothing yet. The daily refresh fills this in while you are not playing music, on Wi-Fi.") }
    static func knownTracks(_ n: Int) -> String { String(localized: "\(n) tracks have facts stored") }
    static func knownGenre(_ n: Int, _ p: Int) -> String { String(localized: "\(n) with a genre (\(p)%)") }
    static func knownYear(_ n: Int, _ p: Int) -> String { String(localized: "\(n) with a year (\(p)%)") }
    static func knownPopularity(_ n: Int, _ p: Int) -> String { String(localized: "\(n) with a popularity (\(p)%)") }
    static func knownEnergy(_ n: Int, _ p: Int) -> String { String(localized: "\(n) with an energy and a mood (\(p)%)") }
    static func knownTempo(_ n: Int, _ p: Int) -> String { String(localized: "\(n) with a tempo (\(p)%)") }
    static func knownArtists(_ n: Int, _ withGenres: Int) -> String { String(localized: "\(n) artists known, \(withGenres) with a genre") }
    static func knownMisses(_ n: Int) -> String { String(localized: "\(n) lookups are waiting out a quiet period after finding nothing") }

    static var sourcesSection: String { String(localized: "Sources") }
    static func sourceToday(_ n: Int, _ limit: Int) -> String { String(localized: "\(n) of \(limit) requests today") }
    static func sourceAnswered(_ n: Int) -> String { String(localized: "\(n) tracks answered") }
    static func sourceLast(_ ago: String) -> String { String(localized: "Last asked \(ago)") }
    static var sourceNever: String { String(localized: "Not asked yet") }
    static var sourceRemoteOff: String { String(localized: "Switched off for every phone") }

    static var spotifySection: String { String(localized: "Spotify") }
    static func spotifyGenres(_ n: Int, _ total: Int) -> String { String(localized: "\(n) of \(total) top artists came with genres") }
    static func spotifyGenresNone(_ total: Int) -> String {
        String(localized: "None of \(total) top artists came with genres. Spotify may no longer send them to this app.")
    }
    static var spotifyOff: String { String(localized: "Off: Spotify facts and genres are not used") }
    static var spotifyEmpty: String { String(localized: "No top artists synced yet") }
    static func youTubeToday(_ n: Int, _ limit: Int) -> String { String(localized: "YouTube Music: \(n) of \(limit) requests today") }

    static var lastRunNone: String { String(localized: "The daily refresh has not run yet") }
    static func lastRun(_ r: BrainDataReport) -> String {
        guard let note = r.lastRun else { return lastRunNone }
        let when = ago(nowMs: r.nowMs, thenMs: note.atMs)
        let stop = stopWord(BrainDataFormat.stop(note.stopped))
        return String(localized: "Last refresh \(when): \(note.radios) radios, \(note.artists) artists, \(note.releases) releases, \(note.tracksEnriched) tracks filled in. Ended: \(stop)")
    }

    static func stopWord(_ stop: BrainDataFormat.Stop) -> String {
        switch stop {
        case .done: String(localized: "finished")
        case .off: String(localized: "a switch was off")
        case .playing: String(localized: "music was playing")
        case .budget: String(localized: "every YouTube request for the day was used")
        case .time: String(localized: "it ran out of time")
        }
    }

    static func ago(nowMs: Int64, thenMs: Int64) -> String {
        switch BrainDataFormat.ago(nowMs: nowMs, thenMs: thenMs) {
        case .now: String(localized: "just now")
        case .minutes(let n): String(localized: "\(n) minutes ago")
        case .hours(let n): String(localized: "\(n) hours ago")
        case .days(let n): String(localized: "\(n) days ago")
        }
    }
}
