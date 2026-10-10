// Which commit and day this build came from. This committed stub says "local build"; CI overwrites it just before the
// build (ci/write-build-identity.sh) with the real commit and date, so the phone can tell which build it runs.
// Never commit a generated version.
nonisolated enum BuildStamp {
    static let gitSHA = "local"
    static let builtOn = "local build"
}
