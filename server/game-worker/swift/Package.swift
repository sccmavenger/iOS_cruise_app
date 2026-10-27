// swift-tools-version: 6.2
// The game rules compiled to WebAssembly for the Room Durable Object. `build-rules.sh` copies
// the rules in from iso_cruise_app/Games (the copies are gitignored), so there is one source.
import PackageDescription

let package = Package(
    name: "CruiseGameServerRules",
    targets: [
        .target(name: "CruiseGameRules", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "RulesWasm",
            dependencies: ["CruiseGameRules"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"])]
        ),
        // Native reference build: records requests and responses for the parity check.
        .executableTarget(name: "golden", dependencies: ["CruiseGameRules"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
