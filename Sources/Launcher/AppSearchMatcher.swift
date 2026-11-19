import Foundation

/// How well a query matched, best first. The order is the whole ranking: an
/// app that matched at a better tier always sorts above one that did not,
/// which is what keeps "not" finding Notes before iNote Pro.
import CLaunchpadCore

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

    static func tier(for query: String, in app: SearchableApplication, queryTokens: Data? = nil) -> MatchTier? {
        guard !query.isEmpty, app.rustSearchSafe, query.count == query.unicodeScalars.count else {
            return fallbackTier(for: query, in: app, rustMatching: true, queryTokens: queryTokens)
        }
        let bytes = query.utf8
        guard let count = UInt32(exactly: bytes.count) else { return fallbackTier(for: query, in: app, rustMatching: true, queryTokens: queryTokens) }
        var length = count.littleEndian
        var packed = Data()
        withUnsafeBytes(of: &length) { packed.append(contentsOf: $0) }
        packed.append(contentsOf: bytes)
        packed.append(app.rustFields)
        let tier = packed.withUnsafeBytes { bytes in
            launchpad_search_tier(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
        }
        if tier == -2 {
            let queryTokens = queryTokens ?? graphemeTokens(query)
            return rustSubsequence(query, of: app.name, queryTokens: queryTokens, textTokens: app.rustGraphemes?[0])
                || rustSubsequence(query, of: app.originalName, queryTokens: queryTokens, textTokens: app.rustGraphemes?[1])
                || rustSubsequence(query, of: app.latinReading, queryTokens: queryTokens, textTokens: app.rustGraphemes?[2])
                || (!app.alias.isEmpty && rustSubsequence(query, of: app.alias, queryTokens: queryTokens, textTokens: app.rustGraphemes?[3])) ? .subsequence : nil
        }
        return MatchTier(rawValue: Int(tier))
    }

    static func fallbackTier(for query: String, in app: SearchableApplication, rustMatching: Bool = false, queryTokens: Data? = nil) -> MatchTier? {
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
        func matches(_ text: String, _ index: Int) -> Bool {
            if rustMatching {
                return rustSubsequence(query, of: text, queryTokens: queryTokens ?? graphemeTokens(query), textTokens: app.rustGraphemes?[index])
            }
            return isSubsequence(query, of: text)
        }
        if matches(app.name, 0)
            || matches(app.originalName, 1)
            || matches(app.latinReading, 2)
            || (hasAlias && matches(app.alias, 3)) {
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

    static func rustSubsequence(_ query: String, of text: String) -> Bool {
        rustSubsequence(query, of: text, queryTokens: graphemeTokens(query), textTokens: graphemeTokens(text))
    }

    static func graphemeTokens(_ input: String) -> Data? {
        let characters = input.filter { $0.isLetter || $0.isNumber }
        guard let count = UInt32(exactly: characters.count) else { return nil }
        var packed = Data()
        var countLE = count.littleEndian
        withUnsafeBytes(of: &countLE) { packed.append(contentsOf: $0) }
        for character in characters {
            let bytes = String(character).precomposedStringWithCanonicalMapping.utf8
            guard let size = UInt32(exactly: bytes.count) else { return nil }
            var sizeLE = size.littleEndian
            withUnsafeBytes(of: &sizeLE) { packed.append(contentsOf: $0) }
            packed.append(contentsOf: bytes)
        }
        return packed
    }

    static func rustSubsequence(_ query: String, of text: String, queryTokens: Data?, textTokens: Data?) -> Bool {
        guard let queryTokens, let textTokens = textTokens ?? graphemeTokens(text) else { return isSubsequence(query, of: text) }
        var packed = queryTokens
        packed.append(textTokens)
        let result = packed.withUnsafeBytes { bytes in
            launchpad_match_graphemes(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
        }
        return result < 0 ? isSubsequence(query, of: text) : result == 1
    }
}
