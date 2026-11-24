// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MacAuthenticator",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "TOTP"),
        .target(name: "Vault", dependencies: ["TOTP"]),
        .executableTarget(name: "MacAuthenticator", dependencies: ["TOTP", "Vault"]),
        .testTarget(name: "TOTPTests", dependencies: ["TOTP"]),
        .testTarget(name: "VaultTests", dependencies: ["Vault", "TOTP"]),
    ]
)
