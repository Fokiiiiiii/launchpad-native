import Catalog
import Foundation

/// One application's text, normalized once so a keystroke does not rebuild it.
///
/// The filter runs synchronously on every character typed. Lowercasing five
/// strings per record inside that loop meant a catalog of a thousand apps
/// allocated five thousand throwaway strings per keystroke; this is built when
/// the catalog changes instead, which is orders of magnitude less often.
struct SearchableApplication {
    let record: ApplicationRecord
    /// Lowercased and diacritic-folded, so "Café" is reachable as "cafe".
    let name: String
    let originalName: String
    /// The name the user gave this app themselves, folded like the others, or
    /// empty when they have not renamed it. Kept alongside the catalog names
    /// rather than replacing them: someone who renames メモ to "notepad"
    /// should still find it by typing either.
    let alias: String
    let bundleIdentifier: String
    let fileName: String
    let category: String
    /// The first letter of each word in the name: "Visual Studio Code" → "vsc".
    let initials: String
    /// Word-start positions in `name`, for matching how people abbreviate:
    /// typing "code" should find "Visual Studio Code" ahead of anything that
    /// merely contains those letters somewhere in the middle.
    let words: [Substring]
    /// A Latin reading of a name written in Japanese, empty otherwise. Lets
    /// メモ be found by typing "memo" on a keyboard that is not in kana mode.
    let latinReading: String
    let latinReadingWords: [Substring]
    let latinReadingInitials: String

    /// `originalName` is separable for tests that need a Japanese display
    /// name alongside the English bundle name the real catalog would carry.
    init(record: ApplicationRecord, originalName: String? = nil, alias: String? = nil) {
        self.record = record
        let name = Self.fold(record.displayName)
        self.name = name
        self.originalName = Self.fold(originalName ?? record.originalDisplayName)
        self.alias = alias.map(Self.fold) ?? ""
        self.bundleIdentifier = Self.fold(record.bundleIdentifier)
        self.fileName = Self.fold(record.bundleURL.deletingPathExtension().lastPathComponent)
        self.category = Self.fold(record.category ?? "")
        let words = Self.words(in: name)
        self.words = words
        self.initials = String(words.compactMap(\.first))

        let reading = LatinReading.of(record.displayName)
        self.latinReading = reading
        let readingWords = Self.words(in: reading)
        self.latinReadingWords = readingWords
        self.latinReadingInitials = String(readingWords.compactMap(\.first))
    }

    /// Case and diacritics are noise for matching: someone typing quickly will
    /// not reach for an accented character to find an app they can see.
    ///
    /// Most names and every bundle identifier are plain ASCII, where lowering
    /// the case is the whole job. `folding` consults Unicode normalization
    /// tables and costs several times as much, so it is kept for the strings
    /// that actually need it.
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Splits on the seams people abbreviate at: whitespace, punctuation, and
    /// the lower-to-upper transition inside a name like "FaceTime".
    static func words(in foldedText: String) -> [Substring] {
        foldedText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}
