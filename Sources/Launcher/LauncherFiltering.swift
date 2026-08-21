import Catalog
import Foundation

/// Pure filtering logic, deliberately free of AppKit so it can be
/// unit-tested without a window server. Matches against both the (possibly
/// aliased later, Phase 6) display name and the original bundle name, per
/// "検索はaliasと元名の両方へ一致" — alias matching itself lands in Phase 6
/// once `LayoutDocument.aliases` is wired in; this is the substring/sort core
/// both use.
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

        guard !trimmed.isEmpty else { return base }

        // The prefix-ranking flag is computed once per record instead of
        // inside the comparator. `sorted` calls its comparator O(n log n)
        // times, and the previous version rebuilt `trimmed.lowercased()` plus
        // `displayName.lowercased()` on *both* sides of every comparison —
        // around 20,000 throwaway string allocations for a 1,000-app catalog,
        // which pushed this synchronous, called-on-every-keystroke filter to
        // 26-41ms, well past the one-frame budget its own test asserts.
        // Prefix matches remain first, while each group keeps the caller's
        // order so search follows the main grid instead of a second sort.
        let loweredQuery = trimmed.lowercased()
        let ranked = base.enumerated().compactMap { offset, record -> (record: ApplicationRecord, rank: Int, order: Int)? in
            let loweredDisplay = record.displayName.lowercased()
            let loweredOriginal = record.originalDisplayName.lowercased()
            let loweredBundleID = record.bundleIdentifier.lowercased()
            let loweredFileName = record.bundleURL.deletingPathExtension().lastPathComponent.lowercased()
            let loweredCategory = record.category?.lowercased() ?? ""

            let displayPrefix = loweredDisplay.hasPrefix(loweredQuery)
                || loweredOriginal.hasPrefix(loweredQuery)
            let displayMatch = loweredDisplay.contains(loweredQuery)
                || loweredOriginal.contains(loweredQuery)
            let metadataMatch = loweredBundleID.contains(loweredQuery)
                || loweredFileName.contains(loweredQuery)
                || loweredCategory.contains(loweredQuery)
            let fuzzyDisplayMatch = fuzzyMatch(loweredQuery, in: loweredDisplay)
                || fuzzyMatch(loweredQuery, in: loweredOriginal)
            let fuzzyMetadataMatch = fuzzyMatch(loweredQuery, in: loweredBundleID)
                || fuzzyMatch(loweredQuery, in: loweredFileName)
                || fuzzyMatch(loweredQuery, in: loweredCategory)
            guard displayMatch || metadataMatch || fuzzyDisplayMatch || fuzzyMetadataMatch else { return nil }
            let rank = displayPrefix
                ? 0
                : displayMatch
                    ? 1
                    : fuzzyDisplayMatch
                        ? 2
                        : metadataMatch ? 3 : 4
            return (record, rank, offset)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.order < rhs.order
            }
            .map(\.record)
    }

    private static func fuzzyMatch(_ query: String, in text: String) -> Bool {
        let query = query.filter { $0.isLetter || $0.isNumber }
        guard !query.isEmpty else { return false }
        var index = query.startIndex
        for character in text where character.isLetter || character.isNumber {
            if character == query[index] {
                index = query.index(after: index)
                if index == query.endIndex { return true }
            }
        }
        return false
    }
}
