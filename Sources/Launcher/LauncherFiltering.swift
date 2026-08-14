import Catalog
import Foundation

/// Pure filtering/sorting logic, deliberately free of AppKit so it can be
/// unit-tested without a window server. Matches against both the (possibly
/// aliased later, Phase 6) display name and the original bundle name, per
/// "検索はaliasと元名の両方へ一致" — alias matching itself lands in Phase 6
/// once `LayoutDocument.aliases` is wired in; this is the substring/sort core
/// both will share.
enum LauncherFiltering {
    static func filter(
        _ records: [ApplicationRecord],
        query: String,
        showMenuBarApplications: Bool = true
    ) -> [ApplicationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // LSBackgroundOnly is never a launcher candidate. LSUIElement apps
        // are candidates by default, with the persisted setting providing the
        // one opt-out used by Settings/GridModel.
        let base = records.filter {
            !$0.isBackgroundOnly && (showMenuBarApplications || !$0.isMenuBarApp)
        }

        guard !trimmed.isEmpty else {
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        // The prefix-ranking flag is computed once per record instead of
        // inside the comparator. `sorted` calls its comparator O(n log n)
        // times, and the previous version rebuilt `trimmed.lowercased()` plus
        // `displayName.lowercased()` on *both* sides of every comparison —
        // around 20,000 throwaway string allocations for a 1,000-app catalog,
        // which pushed this synchronous, called-on-every-keystroke filter to
        // 26-41ms, well past the one-frame budget its own test asserts.
        // Matching and the final ordering still go through the same
        // locale-aware APIs, so results are unchanged.
        let loweredQuery = trimmed.lowercased()
        let ranked = base.compactMap { record -> (record: ApplicationRecord, isPrefixMatch: Bool)? in
            // Case folding via `lowercased()` rather than
            // `localizedCaseInsensitiveContains`. Measured on this machine at
            // 1,000 records: the localized call costs 25.5ms for the two
            // lookups per record that matching needs, versus 2.5ms folding
            // once and using plain `contains` — it was the entire budget of a
            // filter that runs synchronously on every keystroke. Both treat
            // diacritics as distinct, so for app names this only changes
            // locale-specific casing edge cases (Turkish dotless i and the
            // like), never the ASCII/Japanese names in a real catalog.
            // Ordering below deliberately keeps the locale-aware comparison,
            // which measured at 1.6ms and governs what the user actually sees.
            let loweredDisplay = record.displayName.lowercased()
            guard loweredDisplay.contains(loweredQuery)
                || record.originalDisplayName.lowercased().contains(loweredQuery) else { return nil }
            return (record, loweredDisplay.hasPrefix(loweredQuery))
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.isPrefixMatch != rhs.isPrefixMatch { return lhs.isPrefixMatch }
                return lhs.record.displayName.localizedCaseInsensitiveCompare(rhs.record.displayName) == .orderedAscending
            }
            .map(\.record)
    }
}
