import Foundation
import PixlModel

/// The eight settings of Spatial audio and Enhanced audio in `UserDefaults`, under the spec's own names
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
                                 enhancedEnabled: bool(CloudAudioSettingsKey.enhancedEnabled),
                                 storageMB: number(CloudAudioSettingsKey.storageMB)?.intValue,
                                 monthlyCapUSD: number(CloudAudioSettingsKey.monthlyCapUSD)?.doubleValue,
                                 dailyAhead: number(CloudAudioSettingsKey.dailyAhead)?.intValue)
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

    func setEnhancedEnabled(_ isOn: Bool) {
        defaults.set(isOn, forKey: CloudAudioSettingsKey.enhancedEnabled)
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

    /// Forgets every stored value: all eight settings follow their defaults again.
    func reset() {
        for key in CloudAudioSettingsKey.all { defaults.removeObject(forKey: key) }
    }

    private func bool(_ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private func number(_ key: String) -> NSNumber? {
        defaults.object(forKey: key) as? NSNumber
    }
}
