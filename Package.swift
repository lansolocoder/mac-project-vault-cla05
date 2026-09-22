// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProjectVault",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macvault", targets: ["MacVault"])
    ],
    targets: [
        .executableTarget(
            name: "MacVault",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
