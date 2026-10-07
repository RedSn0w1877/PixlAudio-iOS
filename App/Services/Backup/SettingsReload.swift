import Foundation

// After a backup restore wrote new values into `UserDefaults`, the observable settings objects re-read them, so the
// running app follows (Android's DataStore flows do this by themselves). Each category builds a fresh instance from
// the same defaults and copies the values that changed; screens that read a setting only at launch pick it up on
// the next start (the restore report says so).

extension SettingsStore {
    func reload(from defaults: UserDefaults) {
        appearance.reload(from: AppearanceSettings(defaults: defaults))
        behavior.reload(from: BehaviorSettings(defaults: defaults))
        playback.reload(from: PlaybackSettings(defaults: defaults))
        library.reload(from: LibrarySettings(defaults: defaults))
        lyrics.reload(from: LyricsSettings(defaults: defaults))
        equalizer.reload(from: EqualizerPreferences(defaults: defaults))
        ai.reload(from: AISettings(defaults: defaults))
        experimental.reload(from: ExperimentalSettings(defaults: defaults))
    }
}

/// Copies one property when it differs (assigning runs the `didSet` that writes it back, so skip equal values).
private func sync<Root: AnyObject, Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Root, Value>,
                                                     _ target: Root, _ fresh: Root) {
    let value = fresh[keyPath: keyPath]
    if target[keyPath: keyPath] != value { target[keyPath: keyPath] = value }
}

extension AppearanceSettings {
    func reload(from f: AppearanceSettings) {
        sync(\.appThemeMode, self, f)
        sync(\.playerTheme, self, f)
        sync(\.paletteStyle, self, f)
        sync(\.colorAccuracy, self, f)
        // The accent re-tints the running app at once (ThemeStore observes it).
        sync(\.accentColor, self, f)
        sync(\.showScrollbar, self, f)
        sync(\.disableBlurAllOver, self, f)
        sync(\.carouselStyle, self, f)
        sync(\.navBarStyle, self, f)
        sync(\.navBarCompactMode, self, f)
        sync(\.collagePattern, self, f)
        sync(\.collageAutoRotate, self, f)
        sync(\.libraryNavigationMode, self, f)
        sync(\.fullPlayerShowFileInfo, self, f)
        sync(\.albumArtQuality, self, f)
    }
}

extension BehaviorSettings {
    func reload(from f: BehaviorSettings) {
        sync(\.hapticsEnabled, self, f)
        sync(\.tapBackgroundClosesPlayer, self, f)
        sync(\.launchTab, self, f)
        sync(\.folderBackGestureNavigation, self, f)
    }
}

extension PlaybackSettings {
    func reload(from f: PlaybackSettings) {
        sync(\.keepPlayingInBackground, self, f)
        sync(\.isCrossfadeEnabled, self, f)
        sync(\.crossfadeDurationMs, self, f)
        sync(\.repeatMode, self, f)
        sync(\.isShuffleOn, self, f)
        sync(\.persistentShuffleEnabled, self, f)
        sync(\.resumeOnHeadsetReconnect, self, f)
        sync(\.showQueueHistory, self, f)
        sync(\.replayGainEnabled, self, f)
        sync(\.replayGainUseAlbumGain, self, f)
        sync(\.pauseOnVolumeZero, self, f)
        sync(\.automaticInstrumentals, self, f)
        sync(\.hiFiModeEnabled, self, f)
        sync(\.audioQuality, self, f)
        sync(\.playerAmbientStyle, self, f)
        sync(\.globalTransitionSettingsJSON, self, f)
    }
}

extension LibrarySettings {
    func reload(from f: LibrarySettings) {
        sync(\.minSongDurationMs, self, f)
        sync(\.minTracksPerAlbum, self, f)
        sync(\.extractArtistsFromTitle, self, f)
        sync(\.groupByAlbumArtist, self, f)
        sync(\.isAlbumsListView, self, f)
        sync(\.isGenreGridView, self, f)
        sync(\.hideLocalMedia, self, f)
        sync(\.albumArtCacheLimitMb, self, f)
        sync(\.artistDelimiters, self, f)
        sync(\.artistWordDelimiters, self, f)
        sync(\.artistSettingsRescanRequired, self, f)
    }
}

extension LyricsSettings {
    func reload(from f: LyricsSettings) {
        sync(\.automaticLyrics, self, f)
        sync(\.autoScanLrcFiles, self, f)
        sync(\.immersiveLyricsEnabled, self, f)
        sync(\.immersiveLyricsTimeoutMs, self, f)
        sync(\.animatedBlurEnabled, self, f)
        sync(\.animatedBlurStrength, self, f)
        sync(\.tapOffsetSpeakerMs, self, f)
        sync(\.tapOffsetBluetoothMs, self, f)
        sync(\.syncDefaultSpeed, self, f)
        sync(\.syncHaptics, self, f)
        sync(\.sourcePreference, self, f)
    }
}

extension EqualizerPreferences {
    func reload(from f: EqualizerPreferences) {
        sync(\.isEnabled, self, f)
        sync(\.presetName, self, f)
        sync(\.bassBoostEnabled, self, f)
        sync(\.bassBoostStrength, self, f)
        sync(\.virtualizerEnabled, self, f)
        sync(\.virtualizerStrength, self, f)
        sync(\.customBands, self, f)
        sync(\.viewMode, self, f)
        sync(\.customPresetsJSON, self, f)
        sync(\.pinnedPresetsJSON, self, f)
    }
}

extension AISettings {
    func reload(from f: AISettings) {
        sync(\.cloudProvider, self, f)
        sync(\.provider, self, f)
        sync(\.providerMigrated, self, f)
        sync(\.safeTokenLimit, self, f)
        sync(\.temperature, self, f)
        sync(\.topP, self, f)
        sync(\.topK, self, f)
        sync(\.maxTokens, self, f)
        sync(\.presencePenalty, self, f)
        sync(\.frequencyPenalty, self, f)
        sync(\.sampleSize, self, f)
        sync(\.digestMode, self, f)
        sync(\.includeExtendedFields, self, f)
    }
}

extension ExperimentalSettings {
    func reload(from f: ExperimentalSettings) {
        sync(\.delayAlbumCarousel, self, f)
        sync(\.delaySongMetadata, self, f)
        sync(\.delayProgressBar, self, f)
        sync(\.delayControls, self, f)
        sync(\.showPlaceholders, self, f)
        sync(\.transparentPlaceholders, self, f)
        sync(\.applyPlaceholdersOnClose, self, f)
        sync(\.switchOnDragRelease, self, f)
        sync(\.appearThresholdPercent, self, f)
        sync(\.closeThresholdPercent, self, f)
        sync(\.vocalAttenuation, self, f)
        sync(\.roformerBaseUrl, self, f)
        sync(\.roformerApiName, self, f)
        if usesKeychain { reloadSecrets() } else { sync(\.roformerApiKey, self, f) }
        sync(\.roformerExtraArg, self, f)
        sync(\.roformerBackendType, self, f)
    }
}
