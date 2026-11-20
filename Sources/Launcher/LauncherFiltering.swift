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
        showMenuBarApplications: Bool = true,
        lastLaunchDates: [String: Date] = [:]
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

        let matches = candidates.enumerated().compactMap { offset, app -> (ApplicationRecord, MatchTier, Date, Int)? in
            guard let tier = AppSearchMatcher.tier(for: trimmed, in: app) else { return nil }
            return (app.record, tier, lastLaunchDates[app.record.id.value] ?? .distantPast, offset)
        }

        // Recency only decides between results that matched equally well. It
        // deliberately cannot lift a result past a better match: someone who
        // typed enough to name an app exactly should get that app, not the one
        // they happened to open yesterday.
        return matches
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                return lhs.3 < rhs.3
            }
            .map(\.0)
    }

    /// Convenience for callers holding plain records — builds the index on the
    /// spot. The launcher keeps a prepared index instead, since normalizing
    /// every record on every keystroke is the cost this split exists to avoid.
    static func filter(
        _ records: [ApplicationRecord],
        query: String,
        showMenuBarApplications: Bool = true,
        lastLaunchDates: [String: Date] = [:]
    ) -> [ApplicationRecord] {
        filter(
            records.map({ SearchableApplication(record: $0) }),
            query: query,
            showMenuBarApplications: showMenuBarApplications,
            lastLaunchDates: lastLaunchDates
        )
    }
}
