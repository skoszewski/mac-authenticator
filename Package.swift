// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MacAuthenticator",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "TOTP"),
        .executableTarget(name: "MacAuthenticator", dependencies: ["TOTP"]),
        .testTarget(name: "TOTPTests", dependencies: ["TOTP"]),
    ]
)
