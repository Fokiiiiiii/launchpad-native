import Foundation

/// How well a query matched, best first. The order is the whole ranking: an
/// app that matched at a better tier always sorts above one that did not,
/// which is what keeps "not" finding Notes before iNote Pro.
enum MatchTier: Int, Comparable {
    /// The query is the whole name.
    case exactName
    /// The query is the whole Latin reading of a Japanese name. As strong a
    /// signal as naming the app outright — someone typing "memo" in full means
    /// メモ, not the app whose English name happens to contain those letters.
    case readingExact
    /// The name starts with the query — how most searches are meant.
    case namePrefix
    /// The reading starts with the query, or the query abbreviates it.
    case readingPrefix
    /// A word inside the name starts with the query: "code" for
    /// "Visual Studio Code".
    case wordStart
    /// A word inside the reading starts with the query: "settei" for
    /// システム設定.
    case readingWordStart
    /// The query is how the name abbreviates: "vsc" for "Visual Studio Code".
    case initials
    /// The query appears somewhere in the name.
    case nameSubstring
    /// The query appears somewhere in the reading.
    case readingSubstring
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
    /// The reading tiers are interleaved with the Latin ones rather than
    /// stacked after them. A Japanese name read in full is a stronger signal
    /// than an English name that merely contains the letters somewhere: typing
    /// "memo" means メモ, not ボイスメモ (whose bundle name is "Voice Memos").
    static func tier(for query: String, in app: SearchableApplication) -> MatchTier? {
        let hasReading = !app.latinReading.isEmpty
        let hasAlias = !app.alias.isEmpty

        if app.name == query || app.originalName == query || (hasAlias && app.alias == query) { return .exactName }
        if hasReading, app.latinReading == query { return .readingExact }
        if app.name.hasPrefix(query) || app.originalName.hasPrefix(query) || (hasAlias && app.alias.hasPrefix(query)) { return .namePrefix }
        if hasReading, app.latinReading.hasPrefix(query) || app.latinReadingInitials.hasPrefix(query) {
            return .readingPrefix
        }
        if app.words.contains(where: { $0.hasPrefix(query) }) { return .wordStart }
        if hasReading, app.latinReadingWords.contains(where: { $0.hasPrefix(query) }) {
            return .readingWordStart
        }
        if !app.initials.isEmpty, app.initials.hasPrefix(query) { return .initials }
        if app.name.contains(query) || app.originalName.contains(query) || (hasAlias && app.alias.contains(query)) { return .nameSubstring }
        if hasReading, app.latinReading.contains(query) { return .readingSubstring }

        if app.bundleIdentifier.contains(query)
            || app.fileName.contains(query)
            || app.category.contains(query) {
            return .metadata
        }

        // Only the names take part in the loosest tier. Threading a query
        // through a bundle identifier matches almost anything — "memo" runs
        // through "com.apple.mobilesms" — and whatever it would have found
        // there, the substring check above already found honestly.
        if isSubsequence(query, of: app.name)
            || isSubsequence(query, of: app.originalName)
            || isSubsequence(query, of: app.latinReading)
            || (hasAlias && isSubsequence(query, of: app.alias)) {
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
