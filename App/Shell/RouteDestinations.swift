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
        case .cloudProcessing: CloudProcessingSettingsView()
        case .cloudQueue: CloudQueueView()
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
        // See-through glass at 92 % (Hoa, 2026-10-07): a full-height sheet turns opaque on iOS 26.
        case .queue: QueueSheet().pixlSheet(detents: [.tallGlass])
        case .songInfo(let songId): SongInfoSheet(songId: songId).pixlSheet(detents: [.tallGlass])
        case .sleepTimer: SleepTimerSheet().sleepTimerPresentation()
        case .lyricsOptions(let songId): LyricsOptionsSheet(songId: songId).pixlSheet()
        case .changelog, .betaInfo, .jobs: HomeInfoSheet(sheet: sheet).pixlSheet()
        case .devices: DevicesSheet() // sizes its own detent
        case .artistPicker(let songId): PlayerArtistPickerSheet(songId: songId) // sizes its own detent
        case .aiPlaylist: AiPlaylistSheet().pixlSheet(detents: [.tallGlass])
        case .taisChat: TaisChatSheet().pixlSheet(detents: [.tallGlass])
        case .cloudConfirm: CloudConfirmSheet().pixlSheet(detents: [.tallGlass])
        }
    }
}

/// Full-screen content for `AppCover`.
struct CoverDestination: View {
    let cover: AppCover

    @Environment(Router.self) private var router

    var body: some View {
        switch cover {
        case .nowPlaying: NowPlayingView()
        case .lyrics: LyricsView()
        // `-screen lyricsSync` UI tests only: the app opens the editor over the lyrics screen and Edit song.
        case .lyricsSync(let songId):
            LyricsSyncEditorView(songId: songId, onClose: { if router.cover == cover { router.dismissCover() } })
        case .setup: SetupView()
        case .editSong(let songId): EditSongSheet(songId: songId)
        case .aiPlaylistLab: AiPlaylistLabView()
        case .backupImport: BackupImportCover()
        case .backupExport: BackupExportCover()
        }
    }
}

extension View {
    /// Registers every `AppRoute` destination. Apply once at the root of each tab's `NavigationStack`. Every route
    /// gets the room the mini player covers (`BottomBarsClearance.pushed`).
    func withAppRoutes() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestination(route: route)
                .bottomBarsClearance(.pushed)
        }
    }
}
