// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CloudflareSpike",
    targets: [
        .target(name: "CruiseGameRules", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "RulesWasm",
            dependencies: ["CruiseGameRules"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"])]
        ),
        .executableTarget(name: "golden", dependencies: ["CruiseGameRules"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
