import Catalog
import Foundation

/// Turns a query into an ordered result list. AppKit-free so the ranking can
/// be exercised in tests without a window server.
enum LauncherFiltering {
    /// Ranked by match quality first, then by the order the caller supplied,
    /// so results follow the grid rather than imposing a second arrangement of
    /// their own.
    static func filter(
        _ index: [SearchableApplication],
        query: String,
        showMenuBarApplications: Bool = true
    ) -> [ApplicationRecord] {
        // LSBackgroundOnly is never a launcher candidate. LSUIElement apps are
        // candidates by default, with the persisted setting the one opt-out.
        let candidates = index.filter {
            !$0.record.isBackgroundOnly && (showMenuBarApplications || !$0.record.isMenuBarApp)
        }

        let trimmed = SearchableApplication.fold(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return candidates.map(\.record) }

        let matches = candidates.enumerated().compactMap { offset, app in
            AppSearchMatcher.tier(for: trimmed, in: app).map { (app.record, $0, offset) }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            }
            .map(\.0)
    }

    /// Convenience for callers holding plain records — builds the index on the
    /// spot. The launcher keeps a prepared index instead, since normalizing
    /// every record on every keystroke is the cost this split exists to avoid.
    static func filter(
        _ records: [ApplicationRecord],
        query: String,
        showMenuBarApplications: Bool = true
    ) -> [ApplicationRecord] {
        filter(
            records.map(SearchableApplication.init(record:)),
            query: query,
            showMenuBarApplications: showMenuBarApplications
        )
    }
}
