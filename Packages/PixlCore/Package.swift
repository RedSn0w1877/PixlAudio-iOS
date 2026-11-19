// swift-tools-version: 6.2
// PixlCore — the pure-Swift logic of PixlAudio. ZERO dependencies. Must build and test on Windows
// (Swift for Windows) and macOS. Every module and test target is declared up front so parallel work
// never needs to edit this manifest (see AGENTS.md).
import PackageDescription

/// Module name → modules it may import. Order matters only for readability.
let modules: [(name: String, dependencies: [String])] = [
    ("PixlFoundation", []),
    ("PixlModel", ["PixlFoundation"]),
    ("PixlLyrics", ["PixlFoundation", "PixlModel"]),
    ("PixlLibrary", ["PixlFoundation", "PixlModel"]),
    ("PixlAudioCore", ["PixlFoundation", "PixlModel"]),
    ("PixlTags", ["PixlFoundation", "PixlModel"]),
    ("PixlNet", ["PixlFoundation", "PixlModel", "PixlLyrics"]),
    ("PixlBackup", ["PixlFoundation", "PixlModel", "PixlLibrary", "PixlLyrics"]),
]

/// Modules a module's TESTS import beyond its own dependencies. PixlBackup depends on PixlLibrary, so PixlLibrary itself
/// cannot import it, but its tests can: the brain's atlas tests gunzip the shipped asset with PixlBackup's pure-Swift
/// inflate and check its SHA-256 with PixlBackup's (stage 2b).
let extraTestDependencies: [String: [String]] = [
    "PixlLibrary": ["PixlBackup"],
]

let package = Package(
    name: "PixlCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: modules.map { Product.library(name: $0.name, targets: [$0.name]) },
    targets: modules.flatMap { module -> [Target] in
        [
            .target(
                name: module.name,
                dependencies: module.dependencies.map { Target.Dependency.target(name: $0) }
            ),
            .testTarget(
                name: "\(module.name)Tests",
                dependencies: [Target.Dependency.target(name: module.name)]
                    + (module.dependencies + (extraTestDependencies[module.name] ?? [])).map { Target.Dependency.target(name: $0) },
                resources: [.copy("Fixtures")]
            ),
        ]
    }
)
