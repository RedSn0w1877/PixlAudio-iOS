// The key that opens App/Resources/CloudDefaults.enc (PixlAudio's built-in cloud keys), as XOR shares
// (`CloudDefaultsKeyShares.combine`). This committed stub has none: a build without the CLOUD_DEFAULTS_KEY secret
// (forks, pull requests, local builds) has no built-in keys, and Cloud processing behaves as before (off, fields empty).
// CI overwrites this file from the secret just before it builds (ci/write-cloud-defaults-key.sh). Never commit a
// generated version: ci/check-forbidden.sh fails when this file holds any share.
nonisolated enum CloudDefaultsKey {
    static let shares: [[UInt8]] = []
}
