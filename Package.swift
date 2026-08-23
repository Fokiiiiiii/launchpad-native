// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LaunchpadNative",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "AppHost",
            dependencies: ["Diagnostics", "Catalog", "Persistence", "Launcher", "Localization", "Grid", "Triggers", "Settings", "WindowBrowser", "Onboarding", "WhatsNew"],
            path: "Sources/AppHost"
        ),
        .target(
            name: "Diagnostics",
            path: "Sources/Diagnostics"
        ),
        .target(
            name: "Localization",
            path: "Sources/Localization",
            resources: [.process("Resources")]
        ),
        .target(
            name: "DesignSystem",
            path: "Sources/DesignSystem"
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
            dependencies: ["Diagnostics", "Catalog", "Grid", "Localization", "DesignSystem"],
            path: "Sources/Launcher"
        ),
        .target(
            name: "Grid",
            dependencies: ["Diagnostics", "Catalog", "Persistence", "WindowBrowser", "Localization", "DesignSystem"],
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
            dependencies: ["Diagnostics", "Catalog", "Persistence", "Grid", "Uninstall", "Localization"],
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
        .target(
            name: "Onboarding",
            dependencies: ["Diagnostics", "Localization", "DesignSystem"],
            path: "Sources/Onboarding"
        ),
        .target(
            name: "WhatsNew",
            dependencies: ["Diagnostics", "Localization", "DesignSystem"],
            path: "Sources/WhatsNew"
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
        .executableTarget(
            name: "PrivilegedHelperProbe",
            path: "Tools/PrivilegedHelperProbe"
        ),
        .executableTarget(
            name: "IconGenerator",
            path: "Tools/IconGenerator"
        ),
        .executableTarget(
            name: "PrivilegedHelperRegistrationProbe",
            path: "Tools/PrivilegedHelperRegistrationProbe"
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
            name: "AppHostTests",
            dependencies: ["AppHost", "Persistence"],
            path: "Tests/AppHostTests"
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
            name: "OnboardingTests",
            dependencies: ["Onboarding"],
            path: "Tests/OnboardingTests"
        ),
        .testTarget(
            name: "UninstallTests",
            dependencies: ["Uninstall", "Catalog"],
            path: "Tests/UninstallTests"
        ),
        .testTarget(
            name: "SettingsTests",
            dependencies: ["Settings", "Uninstall", "Catalog"],
            path: "Tests/SettingsTests"
        ),
        .testTarget(
            name: "WhatsNewTests",
            dependencies: ["WhatsNew"],
            path: "Tests/WhatsNewTests"
        )
    ]
)
