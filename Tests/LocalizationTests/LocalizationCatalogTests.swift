import Foundation
import Testing
@testable import Localization

/// Checks the string catalogs against each other rather than checking that any
/// particular translation is good.
///
/// The failures worth catching here are mechanical and silent: a key added to
/// English and forgotten elsewhere falls back to English at runtime with no
/// error, and a format specifier that does not match its English original
/// either prints the wrong value or crashes `String(format:)` outright — in a
/// language the author does not read, so nobody notices until a user reports it.
private struct Catalog {
    let language: String
    let entries: [String: String]

    var keys: Set<String> { Set(entries.keys) }
}

private func loadCatalogs() -> [Catalog] {
    let bundle = LocalizationBundle.bundle
    return (bundle.localizations.sorted()).compactMap { language in
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
              let entries = NSDictionary(contentsOf: url) as? [String: String]
        else { return nil }
        return Catalog(language: language, entries: entries)
    }
}

/// Extracts printf-style specifiers in order: `%@`, `%d`, `%1$@` and so on.
private func specifiers(in value: String) -> [String] {
    var found: [String] = []
    var iterator = value.startIndex
    while let percent = value[iterator...].firstIndex(of: "%") {
        var cursor = value.index(after: percent)
        var token = "%"
        while cursor < value.endIndex {
            let character = value[cursor]
            token.append(character)
            cursor = value.index(after: cursor)
            // A specifier ends at its conversion character.
            if character.isLetter || character == "%" { break }
        }
        if token != "%%" { found.append(token) }
        iterator = cursor
        if iterator >= value.endIndex { break }
    }
    return found
}

@Test func thereIsMoreThanOneLanguageAndEnglishIsAmongThem() {
    let catalogs = loadCatalogs()
    #expect(catalogs.count >= 2, "found only: \(catalogs.map(\.language))")
    #expect(catalogs.contains { $0.language == "en" })
}

/// A key present in one language and missing in another silently falls back to
/// English — the app looks translated until it reaches that one screen.
@Test func everyLanguageDefinesExactlyTheSameKeys() throws {
    let catalogs = loadCatalogs()
    let english = try #require(catalogs.first { $0.language == "en" })
    for catalog in catalogs where catalog.language != "en" {
        let missing = english.keys.subtracting(catalog.keys).sorted()
        let extra = catalog.keys.subtracting(english.keys).sorted()
        #expect(missing.isEmpty, "\(catalog.language) is missing: \(missing)")
        #expect(extra.isEmpty, "\(catalog.language) has keys English does not: \(extra)")
    }
}

/// `String(format:)` reads its arguments according to the *translated* string.
/// A specifier dropped or reordered in translation prints the wrong value, and
/// a specifier of the wrong type can crash outright.
@Test func formatSpecifiersMatchEnglishInEveryLanguage() throws {
    let catalogs = loadCatalogs()
    let english = try #require(catalogs.first { $0.language == "en" })
    for catalog in catalogs where catalog.language != "en" {
        for (key, englishValue) in english.entries {
            guard let translated = catalog.entries[key] else { continue }
            let expected = specifiers(in: englishValue)
            let actual = specifiers(in: translated)
            #expect(expected == actual, "\(catalog.language) / \(key): expected \(expected), got \(actual)")
        }
    }
}

/// An empty translation renders as blank UI, which reads as a broken app rather
/// than an untranslated one.
@Test func noTranslationIsEmpty() {
    for catalog in loadCatalogs() {
        for (key, value) in catalog.entries where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Issue.record("\(catalog.language) / \(key) is empty")
        }
    }
}

/// Every key the code actually resolves must exist in English, which is the
/// fallback everything else goes through.
///
/// The keys are read out of `L10n.swift` rather than listed here. A hand-written
/// list is wrong the moment someone adds a string — and a test that only checks
/// the keys somebody remembered to add is not checking much. Reading the source
/// is unusual for a unit test, but the question being asked genuinely spans
/// code and resources: does what the code requests exist in what ships?
@Test func englishResolvesEveryKeyTheCodeUses() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LocalizationTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
    let l10nSource = sourceRoot
        .appendingPathComponent("Sources/Localization/L10n.swift")
    let source = try String(contentsOf: l10nSource, encoding: .utf8)

    // Every lookup goes through `string("key", "default")`.
    let pattern = try NSRegularExpression(pattern: #"string\(\s*"([^"]+)"\s*,"#)
    let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
    let requested = Set(matches.compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    })
    #expect(requested.count > 100, "only found \(requested.count) keys — the extraction is probably wrong")

    let catalogs = loadCatalogs()
    let english = try #require(catalogs.first { $0.language == "en" })
    let missing = requested.subtracting(english.keys).sorted()
    #expect(missing.isEmpty, "English is missing keys the code resolves: \(missing)")

    // The reverse is worth knowing too: a key in the catalog that nothing asks
    // for is dead weight translators are still paying to translate.
    let unused = english.keys.subtracting(requested).sorted()
    #expect(unused.isEmpty, "these keys are shipped but never resolved: \(unused)")
}
