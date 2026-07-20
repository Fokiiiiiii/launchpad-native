// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LaunchpadNative",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "AppHost",
            dependencies: ["Diagnostics", "Catalog", "Persistence"],
            path: "Sources/AppHost"
        ),
        .target(
            name: "Diagnostics",
            path: "Sources/Diagnostics"
        ),
        .target(
            name: "Catalog",
            dependencies: ["Diagnostics"],
            path: "Sources/Catalog"
        ),
        .target(
            name: "Persistence",
            dependencies: ["Diagnostics"],
            path: "Sources/Persistence"
        ),
        .executableTarget(
            name: "ContractProbe",
            path: "Tools/ContractProbe"
        ),
        .executableTarget(
            name: "CatalogProbe",
            dependencies: ["Catalog"],
            path: "Tools/CatalogProbe"
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            path: "Tests/DiagnosticsTests"
        ),
        .testTarget(
            name: "CatalogTests",
            dependencies: ["Catalog"],
            path: "Tests/CatalogTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            path: "Tests/PersistenceTests"
        )
    ]
)
