import Foundation

/// The three Cloud Studio secrets (design §5): the Restricted RunPod key and the bucket-scoped R2 key pair.
nonisolated struct CloudSecrets: Sendable, Equatable {
    var runpodKey: String
    var accessKeyId: String
    var secretAccessKey: String

    static let empty = CloudSecrets(runpodKey: "", accessKeyId: "", secretAccessKey: "")

    var isEmpty: Bool { runpodKey.isEmpty && accessKeyId.isEmpty && secretAccessKey.isEmpty }
}

/// Where the secrets live: the Keychain for the app, memory for tests and UI tests.
nonisolated protocol CloudSecretStoring: Sendable {
    func load() -> CloudSecrets
    @discardableResult func save(_ secrets: CloudSecrets) -> Bool
    func deleteAll()
}

/// The Keychain accounts (no access group: product rule 5), `AfterFirstUnlockThisDeviceOnly` so background wakes can
/// read them but they never migrate to another device or into a backup. The names avoid the `_api_key / _model /
/// _base_url / _system_prompt` suffixes, so `SettingsBackup` and `PreferencesModule` never export them; they aren't
/// UserDefaults keys at all. Read off the main actor (Keychain calls can block).
nonisolated struct CloudKeychain: CloudSecretStoring {
    static let runpodAccount = "cloud_studio_runpod_token"
    static let accessKeyAccount = "cloud_studio_r2_key_id"
    static let secretAccount = "cloud_studio_r2_secret"
    static let accounts = [runpodAccount, accessKeyAccount, secretAccount]

    func load() -> CloudSecrets {
        func read(_ account: String) -> String {
            guard let data = try? KeychainStore.data(for: account) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        return CloudSecrets(runpodKey: read(Self.runpodAccount), accessKeyId: read(Self.accessKeyAccount),
                            secretAccessKey: read(Self.secretAccount))
    }

    @discardableResult
    func save(_ secrets: CloudSecrets) -> Bool {
        var ok = true
        for (account, value) in [(Self.runpodAccount, secrets.runpodKey), (Self.accessKeyAccount, secrets.accessKeyId),
                                 (Self.secretAccount, secrets.secretAccessKey)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if trimmed.isEmpty {
                    try KeychainStore.delete(account: account)
                } else {
                    try KeychainStore.set(Data(trimmed.utf8), for: account, thisDeviceOnly: true)
                }
            } catch {
                ok = false
            }
        }
        return ok
    }

    func deleteAll() {
        for account in Self.accounts { try? KeychainStore.delete(account: account) }
    }
}

/// UI tests and unit tests: nothing touches the Keychain.
nonisolated final class CloudMemorySecrets: CloudSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CloudSecrets

    init(_ secrets: CloudSecrets = .empty) { stored = secrets }

    func load() -> CloudSecrets {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func save(_ secrets: CloudSecrets) -> Bool {
        lock.lock()
        stored = secrets
        lock.unlock()
        return true
    }

    func deleteAll() { _ = save(.empty) }
}
