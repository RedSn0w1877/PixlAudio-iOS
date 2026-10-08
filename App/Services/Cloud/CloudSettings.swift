import Foundation
import Observation
import PixlNet

/// Settings › Developer › Experimental › Cloud processing (design §3.5 E, §7.2): the consent switch, where to send
/// songs, what to ask for, and the money guards. Non-secret values live in `UserDefaults` under `cloud_studio_*`
/// (keys PixlBackup's catalogue doesn't know, so backups never carry them); the three keys are in the Keychain
/// (`CloudKeychain`), held here only while the screen edits them.
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

        static let all = [enabled, endpointId, r2Endpoint, bucket, instrumental, lyrics, transcribe, quality, cellular,
                          pricePerSecond, monthlyCap, keysSaved]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secretStore: any CloudSecretStoring

    /// "Send songs to my RunPod account": nothing leaves the phone while this is off.
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    var endpointId: String { didSet { defaults.set(endpointId, forKey: Keys.endpointId) } }
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

    /// The secrets as last loaded or edited (empty until `loadSecrets()`).
    private(set) var secrets: CloudSecrets = .empty
    private(set) var secretsLoaded = false
    /// Keys were saved before but the Keychain has none now.
    private(set) var keysMissing = false
    @ObservationIgnored private var keysSaved: Bool

    init(defaults: UserDefaults, secrets: any CloudSecretStoring) {
        self.defaults = defaults
        secretStore = secrets
        isEnabled = defaults.bool(Keys.enabled, default: false)
        endpointId = defaults.string(Keys.endpointId, default: "")
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
        keysSaved = defaults.bool(Keys.keysSaved, default: false)
    }

    /// Reads the Keychain off the main actor (once; `force` after a restore or a test).
    func loadSecrets(force: Bool = false) async {
        guard force || !secretsLoaded else { return }
        let store = secretStore
        let loaded = await Task.detached(priority: .userInitiated) { store.load() }.value
        secrets = loaded
        secretsLoaded = true
        keysMissing = keysSaved && loaded.isEmpty
    }

    /// Saves edited secrets to the Keychain (off the main actor).
    func updateSecrets(_ new: CloudSecrets) async {
        guard new != secrets else { return }
        secrets = new
        secretsLoaded = true
        keysMissing = false
        let store = secretStore
        _ = await Task.detached(priority: .userInitiated) { store.save(new) }.value
        keysSaved = !new.isEmpty
        defaults.set(keysSaved, forKey: Keys.keysSaved)
    }

    /// "Forget keys": the Keychain items and the saved flag.
    func forgetSecrets() async {
        secrets = .empty
        keysMissing = false
        keysSaved = false
        defaults.set(false, forKey: Keys.keysSaved)
        let store = secretStore
        await Task.detached(priority: .userInitiated) { store.deleteAll() }.value
    }

    /// Everything the clients need, as typed (validated by `CloudConfig`).
    var configInput: CloudConfigInput {
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
