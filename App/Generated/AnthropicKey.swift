// The built-in Anthropic key for Claude (spec A1), as XOR shares of equal length (`ClaudeKeyShares.combine`). This
// committed stub has none: a build without the ANTHROPIC_API_KEY secret (forks, pull requests, local builds) has no
// built-in key, and every AI feature runs on the device as before. CI overwrites this file from the secret just before
// it builds (ci/write-anthropic-key.sh). Never commit a generated version: ci/check-forbidden.sh fails when this file
// holds any share.
nonisolated enum AnthropicKey {
    static let shares: [[UInt8]] = []
}
