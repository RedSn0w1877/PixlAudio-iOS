import Foundation
import PixlModel

/// The eight settings of Spatial audio in `UserDefaults`, under the spec's own names
/// (`CloudAudioSettingsKey`: `spatial.profile`, `spatial.cloud`, `cloudAudio.storageMB`, …; cloud audio spec 6.1).
/// PixlBackup's catalogue does not know these keys, so backups never carry them.
///
/// Reading resolves the stored values through PixlModel's `CloudAudioSettings` (defaults, ranges). Each setter writes
/// one key: a value the person never touched stays unset and keeps following its default (`spatial.cloud` is on
/// exactly while built-in cloud keys exist, until it is switched by hand).
// @unchecked: UserDefaults is thread-safe but not marked Sendable.
nonisolated struct CloudAudioSettingsStore: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The values as stored (nil: never set).
    func stored() -> CloudAudioStoredSettings {
        CloudAudioStoredSettings(profile: defaults.string(forKey: CloudAudioSettingsKey.spatialProfile),
                                 route: defaults.string(forKey: CloudAudioSettingsKey.spatialRoute),
                                 cloud: bool(CloudAudioSettingsKey.spatialCloud),
                                 prepareAhead: bool(CloudAudioSettingsKey.spatialPrepareAhead),
                                 storageMB: number(CloudAudioSettingsKey.storageMB)?.intValue,
                                 monthlyCapUSD: number(CloudAudioSettingsKey.monthlyCapUSD)?.doubleValue,
                                 dailyAhead: number(CloudAudioSettingsKey.dailyAhead)?.intValue,
                                 songsOff: songsOff())
    }

    /// The settings in force. `builtInCloudKeys`: this build carries PixlAudio's own cloud keys and they open.
    func load(builtInCloudKeys: Bool) -> CloudAudioSettings {
        CloudAudioSettings(stored: stored(), builtInCloudKeys: builtInCloudKeys)
    }

    func setProfile(_ selection: SpatialSelection) {
        defaults.set(selection.storageValue, forKey: CloudAudioSettingsKey.spatialProfile)
    }

    func setRoute(_ mode: SpatialRouteMode) {
        defaults.set(mode.rawValue, forKey: CloudAudioSettingsKey.spatialRoute)
    }

    func setCloud(_ isOn: Bool) {
        defaults.set(isOn, forKey: CloudAudioSettingsKey.spatialCloud)
    }

    func setPrepareAhead(_ isOn: Bool) {
        defaults.set(isOn, forKey: CloudAudioSettingsKey.spatialPrepareAhead)
    }

    func setStorageMB(_ megabytes: Int) {
        defaults.set(CloudAudioSettings.clampedStorageMB(megabytes), forKey: CloudAudioSettingsKey.storageMB)
    }

    /// `nil` is "No limit".
    func setMonthlyCapUSD(_ cap: Double?) {
        defaults.set(CloudAudioSettings.storedMonthlyCap(cap), forKey: CloudAudioSettingsKey.monthlyCapUSD)
    }

    func setDailyAhead(_ songs: Int) {
        defaults.set(CloudAudioSettings.clampedDailyAhead(songs), forKey: CloudAudioSettingsKey.dailyAhead)
    }

    /// `spatial.songsOff`: Spatial audio turned off (`off`) or back on for `spotifyId`'s song, from the sheet's "This
    /// song" switch (Hoa, 2026-11-11). The rest of the list is kept as stored.
    func setSongOff(_ spotifyId: String, off: Bool) {
        guard !spotifyId.isEmpty else { return }
        var ids = CloudAudioSettings.songsOff(fromStored: defaults.object(forKey: CloudAudioSettingsKey.songsOff))
        if off { ids.insert(spotifyId) } else { ids.remove(spotifyId) }
        defaults.set(CloudAudioSettings.storedSongsOff(ids), forKey: CloudAudioSettingsKey.songsOff)
    }

    /// Forgets every stored value: all eight settings follow their defaults again.
    func reset() {
        for key in CloudAudioSettingsKey.all { defaults.removeObject(forKey: key) }
    }

    /// The stored list, made safe (`CloudAudioSettings.songsOff(fromStored:)`): a value of another type reads as empty.
    private func songsOff() -> [String]? {
        guard let value = defaults.object(forKey: CloudAudioSettingsKey.songsOff) else { return nil }
        return CloudAudioSettings.storedSongsOff(CloudAudioSettings.songsOff(fromStored: value))
    }

    private func bool(_ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private func number(_ key: String) -> NSNumber? {
        defaults.object(forKey: key) as? NSNumber
    }
}
