import OSLog

extension OSLogEntryLog.Level {
    /// The name written into exported logs. Both the archive and the
    /// single-session report render entries the same way, so the mapping
    /// lives with the type rather than being spelled out in each of them.
    var exportName: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }
}
