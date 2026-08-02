import os

/// Central logging surface for LaunchpadNative. Each subsystem gets its own
/// category so `log stream --predicate 'subsystem == "..."'` can filter cleanly.
public enum DiagnosticsLog {
    public static let subsystem = "com.launchpadnative.app"

    public static let appHost = Logger(subsystem: subsystem, category: "AppHost")
    public static let catalog = Logger(subsystem: subsystem, category: "Catalog")
    public static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    public static let launcher = Logger(subsystem: subsystem, category: "Launcher")
    public static let grid = Logger(subsystem: subsystem, category: "Grid")
    public static let privateAPI = Logger(subsystem: subsystem, category: "PrivateAPI")
    public static let triggers = Logger(subsystem: subsystem, category: "Triggers")
    public static let uninstall = Logger(subsystem: subsystem, category: "Uninstall")
    public static let settings = Logger(subsystem: subsystem, category: "Settings")
    public static let whatsNew = Logger(subsystem: subsystem, category: "WhatsNew")
}
