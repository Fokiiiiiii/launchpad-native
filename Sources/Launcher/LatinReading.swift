import Foundation

/// A Latin reading of Japanese text, so an app whose name is only ever shown
/// in Japanese can still be found from a Latin keyboard.
///
/// This reads the text rather than transliterating it character by character:
/// a general Latin transform renders 写真 as its Chinese reading, which is no
/// use to someone expecting "shashin". The tokenizer's own transcription
/// attribute uses the same reading data the input methods do.
///
/// Only called while building the search index — the tokenizer is far too
/// expensive to run per keystroke.
enum LatinReading {
    /// Empty for text that needs no reading, which is the common case and
    /// avoids paying for the tokenizer on a catalog of Latin-named apps.
    static func of(_ text: String) -> String {
        guard text.contains(where: needsReading) else { return "" }

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, (text as NSString).length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale
        )

        var pieces: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let attribute = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            )
            guard let reading = attribute as? String, !reading.isEmpty else { continue }
            pieces.append(reading)
        }

        guard !pieces.isEmpty else { return "" }
        return SearchableApplication.fold(pieces.joined(separator: " "))
    }

    private static func needsReading(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // kana
                || (0x4E00...0x9FFF).contains(scalar.value)  // CJK ideographs
                || (0x3400...0x4DBF).contains(scalar.value)  // CJK extension A
        }
    }
}
