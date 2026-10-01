import SwiftUI

/// The one place that maps routes to views. Each case points at the view its stage owns (see docs/design.md ›
/// Seams); stages replace those views' bodies and keep their initialisers, so this file rarely changes.
struct RouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .albumDetail(let albumId): AlbumDetailView(albumId: albumId)
        case .artistDetail(let artistId): ArtistDetailView(artistId: artistId)
        case .genreDetail(let genreId): GenreDetailView(genreId: genreId)
        case .playlistDetail(let playlistId): PlaylistDetailView(playlistId: playlistId)
        case .playlistEditor(let playlistId): PlaylistEditorView(playlistId: playlistId)
        case .folderExplorer(let path): FolderExplorerView(path: path)
        case .dailyMix: DailyMixView()
        case .yourMix: YourMixView()
        case .recentlyPlayed: RecentlyPlayedView()
        case .stats: StatsView()
        case .settings: SettingsView()
        case .settingsCategory(let category): SettingsCategoryView(category: category)
        case .paletteStyle: PaletteStyleView()
        case .experimental: ExperimentalSettingsView()
        case .artistSettings: ArtistSettingsView()
        case .delimiterConfig: DelimiterConfigView()
        case .wordDelimiterConfig: WordDelimiterConfigView()
        case .equalizer: EqualizerView()
        case .editTransition(let playlistId): EditTransitionView(playlistId: playlistId)
        case .deviceCapabilities: DeviceCapabilitiesView()
        case .about: AboutView()
        case .openSourceLicenses: OpenSourceLicensesView()
        case .easterEgg: EasterEggView()
        case .quickFill: QuickFillView()
        case .diagnostics: DiagnosticsView()
        case .accounts: AccountsView()
        case .spotifyDashboard: SpotifyDashboardView()
        case .spotifyBrowse(let query): SpotifyBrowseView(query: query)
        case .youTubeLogin: YouTubeLoginView()
        case .playbackDiagnostics: PlaybackDiagnosticsView()
        }
    }
}

/// Sheet content for `AppSheet` (presented by the shell with the system sheet).
struct SheetDestination: View {
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .queue: QueueSheet().pixlSheet(detents: [.large])
        case .songInfo(let songId): SongInfoSheet(songId: songId).pixlSheet(detents: [.large])
        case .sleepTimer: SleepTimerSheet().sleepTimerPresentation()
        case .lyricsOptions(let songId): LyricsOptionsSheet(songId: songId).pixlSheet()
        case .changelog, .betaInfo, .jobs: HomeInfoSheet(sheet: sheet).pixlSheet()
        case .devices: DevicesSheet() // sizes its own detent
        case .artistPicker(let songId): PlayerArtistPickerSheet(songId: songId) // sizes its own detent
        case .aiDJ: AIDJSheet().pixlSheet()
        }
    }
}

/// Full-screen content for `AppCover`.
struct CoverDestination: View {
    let cover: AppCover

    var body: some View {
        switch cover {
        case .nowPlaying: NowPlayingView()
        case .lyrics: LyricsView()
        case .lyricsSync(let songId): LyricsSyncEditorView(songId: songId)
        case .setup: SetupView()
        case .editSong(let songId): EditSongSheet(songId: songId)
        }
    }
}

extension View {
    /// Registers every `AppRoute` destination. Apply once at the root of each tab's `NavigationStack`.
    func withAppRoutes() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestination(route: route)
        }
    }
}
