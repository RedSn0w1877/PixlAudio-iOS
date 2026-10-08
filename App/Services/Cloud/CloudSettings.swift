import Foundation
import Observation
import PixlNet

/// Settings › Developer › Experimental › Cloud processing (design §3.5 E, §7.2): the consent switch, where to send
/// songs, what to ask for, and the money guards. Non-secret values live in `UserDefaults` under `cloud_studio_*`
/// (keys PixlBackup's catalogue doesn't know, so backups never carry them); the three keys are in the Keychain
/// (`CloudKeychain`), held here only while the screen edits them.
///
/// Built-in keys (2026-10-08): a build that carries PixlAudio's own keys (`CloudBuiltInKeysProviding`) uses them
/// unless the person chose "Use my own keys" (`CloudKeyChoice`: own keys always win), and has the feature on until the
/// person switches it off. A build without them, or whose blob doesn't open, behaves exactly as before.
@Observable
final class CloudSettings {
    nonisolated enum Keys {
        static let enabled = "cloud_studio_enabled"
        static let endpointId = "cloud_studio_endpoint_id"
        static let r2Endpoint = "cloud_studio_r2_endpoint"
        static let bucket = "cloud_studio_bucket"
        static let instrumental = "cloud_studio_out_instrumental"
        static let lyrics = "cloud_studio_out_lyrics"
        static let transcribe = "cloud_studio_out_transcribe"
        static let quality = "cloud_studio_quality"
        static let cellular = "cloud_studio_cellular"
        static let pricePerSecond = "cloud_studio_price_micro_usd"
        static let monthlyCap = "cloud_studio_monthly_cap_micro_usd"
        /// Set once keys were saved: if the Keychain later comes back empty (the app was re-signed by another team),
        /// the screen says "Cloud keys missing — paste them again" instead of failing silently.
        static let keysSaved = "cloud_studio_keys_saved"
        /// The endpoint's limits from the last selftest (JSON), forgotten when the Endpoint ID changes.
        static let workerCaps = "cloud_studio_worker_caps"
        /// "Use my own keys" (built-in keys exist in this build); unset until the person first chooses.
        static let useOwnKeys = "cloud_studio_use_own_keys"

        static let all = [enabled, endpointId, r2Endpoint, bucket, instrumental, lyrics, transcribe, quality, cellular,
                          pricePerSecond, monthlyCap, keysSaved, workerCaps, useOwnKeys]
    }

    /// Where the built-in keys stand in this build.
    nonisolated enum BuiltInState: Sendable, Equatable {
        /// The build has none (no key, no blob): the old behaviour.
        case none
        /// Bundled, not decrypted yet (counts as available, so nothing flickers before the first use).
        case pending
        case ready
        /// Bundled but the blob didn't open with this build's key: treated like `none`.
        case failed
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secretStore: any CloudSecretStoring
    @ObservationIgnored private let builtIn: (any CloudBuiltInKeysProviding)?

    /// The person's own choice for the consent switch (nil: never touched, the default applies).
    private var enabledChoice: Bool?
    /// "Send songs to my RunPod account" / "Process songs in the cloud": nothing leaves the phone while this is off.
    /// Until the person touches it, on exactly when built-in keys are available (`CloudKeyChoice.defaultEnabled`).
    var isEnabled: Bool {
        get { enabledChoice ?? CloudKeyChoice.defaultEnabled(builtInAvailable: builtInAvailable) }
        set {
            enabledChoice = newValue
            defaults.set(newValue, forKey: Keys.enabled)
        }
    }
    /// "Use my own keys": the fields below instead of the built-in keys (only shown when the build has them).
    var useOwnKeys: Bool {
        didSet {
            defaults.set(useOwnKeys, forKey: Keys.useOwnKeys)
            // Another endpoint: its limits are unknown until a selftest.
            if useOwnKeys != oldValue, workerCaps != nil { workerCaps = nil }
        }
    }
    private(set) var builtInState: BuiltInState
    /// The decrypted built-in keys (memory only; nil until `loadSecrets()` or when unavailable).
    @ObservationIgnored private var builtInConfig: CloudConfigInput?
    var endpointId: String {
        didSet {
            defaults.set(endpointId, forKey: Keys.endpointId)
            if endpointId != oldValue, workerCaps != nil { workerCaps = nil }
        }
    }
    /// As typed: `https://<account-id>.r2.cloudflarestorage.com` or the bare account ID.
    var r2Endpoint: String { didSet { defaults.set(r2Endpoint, forKey: Keys.r2Endpoint) } }
    var bucket: String { didSet { defaults.set(bucket, forKey: Keys.bucket) } }
    var wantsInstrumental: Bool { didSet { defaults.set(wantsInstrumental, forKey: Keys.instrumental) } }
    var wantsLyrics: Bool { didSet { defaults.set(wantsLyrics, forKey: Keys.lyrics) } }
    /// "Write lyrics when none are found (AI transcription)".
    var transcribeWhenMissing: Bool { didSet { defaults.set(transcribeWhenMissing, forKey: Keys.transcribe) } }
    var quality: CloudSeparationQuality { didSet { defaults.set(quality.rawValue, forKey: Keys.quality) } }
    /// "Use cellular data" (off: uploads and downloads wait for Wi-Fi).
    var useCellular: Bool { didSet { defaults.set(useCellular, forKey: Keys.cellular) } }
    /// The GPU price the estimates use (µ$ per second; default AMPERE_24 $0.000192/s).
    var pricePerSecondMicroUSD: Int64 { didSet { defaults.set(pricePerSecondMicroUSD, forKey: Keys.pricePerSecond) } }
    /// The app's monthly cap (default $3): submissions stop once the month's recorded cost reaches it.
    var monthlyCapMicroUSD: Int64 { didSet { defaults.set(monthlyCapMicroUSD, forKey: Keys.monthlyCap) } }
    /// The endpoint's own limits as its last selftest reported them (nil until one ran): prepared songs over them are
    /// stopped before the upload (`CloudLimits.workerRefusal`).
    var workerCaps: CloudWorkerCaps? {
        didSet {
            if let workerCaps, let data = try? CloudJSON.encode(workerCaps) {
                defaults.set(data, forKey: Keys.workerCaps)
            } else {
                defaults.removeObject(forKey: Keys.workerCaps)
            }
        }
    }

    /// The secrets as last loaded or edited (empty until `loadSecrets()`).
    private(set) var secrets: CloudSecrets = .empty
    private(set) var secretsLoaded = false
    /// Own keys were saved before but the Keychain has none now.
    private var ownKeysMissing = false
    @ObservationIgnored private var keysSaved: Bool

    /// `builtIn`: this build's built-in keys (nil: none, as in tests and the UI-test demo by default).
    init(defaults: UserDefaults, secrets: any CloudSecretStoring, builtIn: (any CloudBuiltInKeysProviding)? = nil) {
        self.defaults = defaults
        secretStore = secrets
        self.builtIn = builtIn
        builtInState = builtIn?.isBundled == true ? .pending : .none
        enabledChoice = defaults.object(forKey: Keys.enabled) == nil ? nil : defaults.bool(forKey: Keys.enabled)
        let savedEndpointId = defaults.string(Keys.endpointId, default: "")
        let savedKeys = defaults.bool(Keys.keysSaved, default: false)
        useOwnKeys = defaults.object(forKey: Keys.useOwnKeys) == nil
            ? CloudKeyChoice.defaultUseOwnKeys(keysSaved: savedKeys, endpointId: savedEndpointId)
            : defaults.bool(forKey: Keys.useOwnKeys)
        endpointId = savedEndpointId
        r2Endpoint = defaults.string(Keys.r2Endpoint, default: "")
        bucket = defaults.string(Keys.bucket, default: CloudConfig.defaultBucket)
        wantsInstrumental = defaults.bool(Keys.instrumental, default: true)
        wantsLyrics = defaults.bool(Keys.lyrics, default: true)
        transcribeWhenMissing = defaults.bool(Keys.transcribe, default: true)
        quality = CloudSeparationQuality(rawValue: defaults.string(Keys.quality, default: "")) ?? .standard
        useCellular = defaults.bool(Keys.cellular, default: false)
        let price = (defaults.object(forKey: Keys.pricePerSecond) as? NSNumber)?.int64Value
        pricePerSecondMicroUSD = price.map { min(max($0, 1), 10_000) } ?? CloudCost.defaultPricePerSecondMicroUSD
        let cap = (defaults.object(forKey: Keys.monthlyCap) as? NSNumber)?.int64Value
        monthlyCapMicroUSD = cap.map { min(max($0, 0), 1_000_000_000) } ?? CloudCost.defaultMonthlyCapMicroUSD
        keysSaved = savedKeys
        workerCaps = defaults.data(forKey: Keys.workerCaps).flatMap { try? CloudJSON.decode(CloudWorkerCaps.self, from: $0) }
    }

    /// Reads the Keychain off the main actor (once; `force` after a restore or a test), and opens the built-in keys
    /// the first time (off the main actor too).
    func loadSecrets(force: Bool = false) async {
        await loadBuiltInKeys()
        guard force || !secretsLoaded else { return }
        let store = secretStore
        let loaded = await Task.detached(priority: .userInitiated) { store.load() }.value
        secrets = loaded
        secretsLoaded = true
        ownKeysMissing = keysSaved && loaded.isEmpty
    }

    /// Decrypts the built-in keys once (they are kept in memory only).
    func loadBuiltInKeys() async {
        guard builtInState == .pending, let builtIn else { return }
        let config = await builtIn.load()
        guard builtInState == .pending else { return }
        builtInConfig = config
        builtInState = config == nil ? .failed : .ready
    }

    // MARK: Whose keys

    /// This build has built-in keys that open (or haven't been opened yet).
    var builtInAvailable: Bool { builtInState == .pending || builtInState == .ready }

    /// Whose keys jobs go out with now.
    var keySource: CloudKeySource { CloudKeyChoice.source(useOwnKeys: useOwnKeys, builtInAvailable: builtInAvailable) }

    var usesBuiltInKeys: Bool { keySource == .builtIn }

    /// Own keys were saved before but can't be read any more, and they are the ones in use.
    var keysMissing: Bool { ownKeysMissing && !usesBuiltInKeys }

    /// The cap the money guards use: the field's, but never above $3 a month with the built-in keys.
    var effectiveMonthlyCapMicroUSD: Int64 {
        CloudKeyChoice.effectiveMonthlyCap(monthlyCapMicroUSD, source: keySource)
    }

    /// Saves edited secrets to the Keychain (off the main actor).
    func updateSecrets(_ new: CloudSecrets) async {
        guard new != secrets else { return }
        secrets = new
        secretsLoaded = true
        ownKeysMissing = false
        let store = secretStore
        _ = await Task.detached(priority: .userInitiated) { store.save(new) }.value
        keysSaved = !new.isEmpty
        defaults.set(keysSaved, forKey: Keys.keysSaved)
    }

    /// "Forget keys": the Keychain items and the saved flag.
    func forgetSecrets() async {
        secrets = .empty
        ownKeysMissing = false
        keysSaved = false
        defaults.set(false, forKey: Keys.keysSaved)
        let store = secretStore
        await Task.detached(priority: .userInitiated) { store.deleteAll() }.value
    }

    /// Everything the clients need: the built-in keys when they are in use (empty until decrypted, so nothing is
    /// sent half-configured), else the fields as typed (validated by `CloudConfig`).
    var configInput: CloudConfigInput {
        usesBuiltInKeys ? (builtInConfig ?? .empty) : ownConfigInput
    }

    /// The person's own fields, whichever keys are in use.
    var ownConfigInput: CloudConfigInput {
        CloudConfigInput(endpointId: endpointId, runpodKey: secrets.runpodKey, endpoint: r2Endpoint, bucket: bucket,
                         accessKeyId: secrets.accessKeyId, secretAccessKey: secrets.secretAccessKey)
    }

    /// The selection rules' options.
    var selectionOptions: CloudSelectionOptions {
        CloudSelectionOptions(instrumental: wantsInstrumental, lyrics: wantsLyrics,
                              transcribeWhenMissing: transcribeWhenMissing)
    }

    /// Switched on and every field filled in.
    var isReady: Bool { isEnabled && secretsLoaded && configInput.isComplete }
}
