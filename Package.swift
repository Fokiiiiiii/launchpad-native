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
            dependencies: ["Diagnostics", "Catalog", "Persistence", "Launcher", "Grid", "Triggers", "Settings", "WindowBrowser"],
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
        .target(
            name: "Launcher",
            dependencies: ["Diagnostics", "Catalog", "Grid"],
            path: "Sources/Launcher"
        ),
        .target(
            name: "Grid",
            dependencies: ["Diagnostics", "Catalog", "Persistence", "WindowBrowser"],
            path: "Sources/Grid",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "Triggers",
            dependencies: ["Diagnostics", "Persistence"],
            path: "Sources/Triggers"
        ),
        .target(
            name: "Settings",
            dependencies: ["Diagnostics", "Catalog", "Persistence", "Grid", "Uninstall"],
            path: "Sources/Settings"
        ),
        .target(
            name: "WindowBrowser",
            dependencies: ["Diagnostics"],
            path: "Sources/WindowBrowser"
        ),
        .target(
            name: "Uninstall",
            dependencies: ["Diagnostics", "Catalog", "Persistence"],
            path: "Sources/Uninstall"
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
        .executableTarget(
            name: "MultitouchProbe",
            path: "Tools/MultitouchProbe"
        ),
        .executableTarget(
            name: "WindowBrowserProbe",
            dependencies: ["WindowBrowser"],
            path: "Tools/WindowBrowserProbe"
        ),
        .executableTarget(
            name: "UninstallFixtureProbe",
            dependencies: ["Uninstall", "Catalog"],
            path: "Tools/UninstallFixtureProbe"
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
        ),
        .testTarget(
            name: "LauncherTests",
            dependencies: ["Launcher"],
            path: "Tests/LauncherTests"
        ),
        .testTarget(
            name: "GridTests",
            dependencies: ["Grid"],
            path: "Tests/GridTests"
        ),
        .testTarget(
            name: "TriggersTests",
            dependencies: ["Triggers"],
            path: "Tests/TriggersTests"
        ),
        .testTarget(
            name: "WindowBrowserTests",
            dependencies: ["WindowBrowser"],
            path: "Tests/WindowBrowserTests"
        ),
        .testTarget(
            name: "UninstallTests",
            dependencies: ["Uninstall", "Catalog"],
            path: "Tests/UninstallTests"
        )
    ]
)
