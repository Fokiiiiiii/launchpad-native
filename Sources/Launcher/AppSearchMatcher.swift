import Foundation

/// How well a query matched, best first. The order is the whole ranking: an
/// app that matched at a better tier always sorts above one that did not,
/// which is what keeps "not" finding Notes before iNote Pro.
enum MatchTier: Int, Comparable {
    /// The query is the whole name.
    case exactName
    /// The name starts with the query — how most searches are meant.
    case namePrefix
    /// A word inside the name starts with the query: "code" for
    /// "Visual Studio Code".
    case wordStart
    /// The query is how the name abbreviates: "vsc" for "Visual Studio Code".
    case initials
    /// The query appears somewhere in the name.
    case nameSubstring
    /// The Latin reading of a Japanese name matched.
    case reading
    /// The bundle identifier, the file on disk, or the app's category.
    case metadata
    /// The query's letters appear in order but not together. Last on purpose:
    /// almost anything matches this way, so it only decides between results
    /// that nothing better claimed.
    case subsequence

    static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Decides how — and whether — one query matches one application.
///
/// Pure and free of AppKit so the ranking can be tested directly, which
/// matters more here than usual: search ranking is easy to change by accident
/// and hard to notice going wrong.
enum AppSearchMatcher {
    static func tier(for query: String, in app: SearchableApplication) -> MatchTier? {
        if app.name == query || app.originalName == query { return .exactName }
        if app.name.hasPrefix(query) || app.originalName.hasPrefix(query) { return .namePrefix }
        if app.words.contains(where: { $0.hasPrefix(query) }) { return .wordStart }
        if !app.initials.isEmpty, app.initials.hasPrefix(query) { return .initials }
        if app.name.contains(query) || app.originalName.contains(query) { return .nameSubstring }

        if !app.latinReading.isEmpty {
            if app.latinReading.hasPrefix(query)
                || app.latinReading.contains(query)
                || app.latinReadingInitials.hasPrefix(query) {
                return .reading
            }
        }

        if app.bundleIdentifier.contains(query)
            || app.fileName.contains(query)
            || app.category.contains(query) {
            return .metadata
        }

        if isSubsequence(query, of: app.name)
            || isSubsequence(query, of: app.originalName)
            || isSubsequence(query, of: app.bundleIdentifier)
            || isSubsequence(query, of: app.fileName)
            || isSubsequence(query, of: app.category) {
            return .subsequence
        }

        return nil
    }

    /// Every character of the query appears in order, ignoring anything that
    /// is not a letter or digit on either side.
    static func isSubsequence(_ query: String, of text: String) -> Bool {
        let wanted = query.filter { $0.isLetter || $0.isNumber }
        guard !wanted.isEmpty else { return false }
        var index = wanted.startIndex
        for character in text where character.isLetter || character.isNumber {
            if character == wanted[index] {
                index = wanted.index(after: index)
                if index == wanted.endIndex { return true }
            }
        }
        return false
    }
}
