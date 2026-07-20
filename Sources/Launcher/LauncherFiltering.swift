import Catalog
import Foundation

/// Pure filtering/sorting logic, deliberately free of AppKit so it can be
/// unit-tested without a window server. Matches against both the (possibly
/// aliased later, Phase 6) display name and the original bundle name, per
/// "検索はaliasと元名の両方へ一致" — alias matching itself lands in Phase 6
/// once `LayoutDocument.aliases` is wired in; this is the substring/sort core
/// both will share.
enum LauncherFiltering {
    static func filter(_ records: [ApplicationRecord], query: String) -> [ApplicationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = records.filter { !$0.isBackgroundOnly }

        guard !trimmed.isEmpty else {
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        return base
            .filter {
                $0.displayName.localizedCaseInsensitiveContains(trimmed)
                    || $0.originalDisplayName.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    || lhs.displayName.lowercased().hasPrefix(trimmed.lowercased())
                let rhsPrefix = rhs.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    || rhs.displayName.lowercased().hasPrefix(trimmed.lowercased())
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}
