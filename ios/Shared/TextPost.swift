// Deterministic post-pass shared by both targets. `enforceDictionary` comes from the macOS app
// (macos/Sources/PrivateWhisper/CorrectionLearner.swift, enforceDictionary/replacement/levenshtein), with one
// deliberate iOS difference: the fuzzy branch is gated so inflected forms and real words the user said are never
// rewritten (Offerten→Offerte, Brunnen→Brunner, Sinon→Simon); only non-words like "Sonepr" → "Sonepar" are.
import Foundation
import UIKit

enum TextPost {
    /// Runs after the guardrails, on both the cleaned and the raw path (spec §6.6).
    @MainActor
    static func finalize(_ text: String, language: DictationLanguage, dictionary: [String]) -> String {
        var t = text
        if language == .gsw { t = t.replacingOccurrences(of: "ß", with: "ss") }   // Swiss orthography never uses ß
        return enforceDictionary(t, dictionary: dictionary, language: language)
    }

    /// Spacing on insert: a leading space unless the cursor follows whitespace or the text starts with
    /// punctuation; a trailing space unless the text ends with a newline.
    static func spaced(_ text: String, before: String?) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        if let last = before?.last, !last.isWhitespace,
           let first = out.first, !(first.isPunctuation) {
            out = " " + out
        }
        if out.last != "\n" { out += " " }
        return out
    }

    /// Deterministic glossary enforcement: replaces output words that are
    /// near-misses of a dictionary term (similarity ≥ 0.8, length ≥ 4) with the
    /// exact dictionary spelling. Runs after cleanup so a term ALWAYS wins even
    /// when whisper and the LLM both fumble it.
    @MainActor
    static func enforceDictionary(_ text: String, dictionary: [String], language: DictationLanguage) -> String {
        guard !dictionary.isEmpty else { return text }
        let terms = dictionary.filter { $0.count >= 4 }
        guard !terms.isEmpty else { return text }
        let checker = UITextChecker()                     // on-device lexicon, no network
        let codes = checkerLanguages(language)
        func isKnownWord(_ w: String) -> Bool {
            let r = NSRange(location: 0, length: (w as NSString).length)
            return codes.contains {
                checker.rangeOfMisspelledWord(in: w, range: r, startingAt: 0, wrap: false, language: $0).location == NSNotFound
            }
        }

        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty {
                result += replacement(for: word, terms: terms, isKnownWord: isKnownWord)
                word = ""
            }
        }
        for ch in text {
            if ch.isLetter || ch == "-" || ch == "'" || ch == "’" {
                word.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    private static func checkerLanguages(_ l: DictationLanguage) -> [String] {
        let available = Set(UITextChecker.availableLanguages)
        let wanted: [String]
        switch l {
        case .en: wanted = ["en_US", "en_GB"]
        case .fr: wanted = ["fr_FR", "fr_CH"]
        case .de, .gsw: wanted = ["de_CH", "de_DE"]
        case .auto: wanted = ["de_DE", "fr_FR", "en_US"]
        }
        return wanted.filter { available.contains($0) }
    }

    private static func replacement(for word: String, terms: [String], isKnownWord: (String) -> Bool) -> String {
        guard word.count >= 4 else { return word }
        let lower = word.lowercased()
        for term in terms where lower == term.lowercased() { return term }   // case/diacritic-exact enforcement
        // Fuzzy only for longer words that are not an inflection of the term and not a real word in the language.
        guard word.count >= 6 else { return word }
        var known: Bool?
        for term in terms {
            let termLower = term.lowercased()
            guard term.count >= 6, lower.first == termLower.first,
                  !lower.hasPrefix(termLower), !termLower.hasPrefix(lower) else { continue }
            let distance = levenshtein(lower, termLower)
            let similarity = 1.0 - Double(distance) / Double(max(word.count, term.count))
            if similarity >= 0.8 {
                if known == nil { known = isKnownWord(word) }
                if known == true { return word }                 // a real word the user said: never rewrite
                return term
            }
        }
        return word
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
