// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/Polish/PolishGuardrail.swift, PolishPrefixAlignment.swift, PolishGrounding.swift (segment overlap and the
// EN/DE/FR function-word lists), PolishLexicon.swift, PolishSegmentation.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// Output validation, cheapest first; the first failure wins (spec §6.5). Returns a reason slug or nil.
// The keyboard never repairs model output: any rejection inserts the raw transcript.
import Foundation
import NaturalLanguage

enum CleanupGuardrail {
    static func rejection(output: String, input: String, languageCode: String) -> String? {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1 empty
        guard !out.isEmpty else { return "empty" }
        // 2 length
        let ratio = Double(out.count) / Double(max(input.count, 1))
        if ratio > 2.0 || (input.count >= 60 && ratio < 0.4) { return "length" }
        // 3 language
        if let bad = languageMismatch(out, expected: languageCode) { return bad }
        let inWords = Set(words(input))
        let outSegments = segments(out)
        // 4 prefixAlignment
        if !prefixAligned(out, inWords: inWords, segments: outSegments) { return "prefixAlignment" }
        // 4b opening: a same-line preamble ("Hier ist der bereinigte Text: …") at any length. Only with a lead-in
        // colon early in the first line, or an output clearly longer than the input, so reconstructed or reordered
        // openings are not refused (Dictus #456).
        if let first = outSegments.first {
            let head = first.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let colonEarly = head.count > 1 && words(String(head[0])).count <= 10
            let grew = Double(out.count) >= 1.2 * Double(input.count)
            let content = words(first).prefix(10).filter { !functionWords.contains($0) }.prefix(3)
            if (colonEarly || grew) && content.count == 3 && !content.contains(where: { inWords.contains($0) }) {
                return "opening"
            }
        }
        // 4c shortSupport: when the 8-word window cannot run (short input or output), most output words must come
        // from the input (catches answers and refusals to short questions). Accepted cost: short slang expansions
        // (gonna → going to) fall back to the raw transcript, which is safe.
        let ow = words(out)
        if (ow.count < 8 || inWords.count < 8) && ow.count >= 3 {
            let share = Double(ow.filter { inWords.contains($0) }.count) / Double(ow.count)
            if share < 0.6 { return "shortSupport" }
        }
        // 5 segmentOverlap
        for seg in outSegments {
            let content = words(seg).filter { !functionWords.contains($0) }
            guard content.count >= 3 else { continue }
            let hit = content.filter { inWords.contains($0) }.count
            if Double(hit) / Double(content.count) < 0.15 { return "segmentOverlap" }
        }
        // 6 promptLeak (iOS 27 example leakage, #570). Keep in sync with shared/prompts/cleanup_prompt.txt.
        let fOut = fold(out), fIn = fold(input)
        for cue in leakCues where fOut.contains(cue) && !fIn.contains(cue) { return "promptLeak" }
        // Swiss example words from the .gsw language line: whole words, only when the input did not have them.
        if !swissCues.intersection(Set(words(out))).subtracting(inWords).isEmpty { return "promptLeak" }
        return nil
    }

    static let swissCues = Set(CleanupPrompt.swissWords.map(fold))

    static let leakCues = ["no wait", "ich meine", "je veux dire", "erstens", "zweitens",
                           "premierement", "deuxiemement", "tuesday", "wednesday"]

    // MARK: checks

    private static func languageMismatch(_ out: String, expected: String) -> String? {
        if out.count >= 12, let (lang, p) = topLanguage(out), p >= 0.5, lang != expected { return "language" }
        let lines = out.split(whereSeparator: \.isNewline).map(String.init).filter { $0.count >= 12 }
        if lines.count > 1 {
            for l in lines {
                if let (lang, p) = topLanguage(l), p >= 0.85, lang != expected { return "language.line" }
            }
        }
        return nil
    }

    private static func topLanguage(_ s: String) -> (String, Double)? {
        let r = NLLanguageRecognizer()              // created per call, never cached (§8.4)
        r.processString(s)
        guard let best = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }) else { return nil }
        return (best.key.rawValue, best.value)
    }

    private static func prefixAligned(_ out: String, inWords: Set<String>, segments: [String]) -> Bool {
        let ow = words(out)
        if ow.count >= 8 && inWords.count >= 8 {
            var found = false
            var i = 0
            while i + 8 <= ow.count {
                if ow[i..<(i + 8)].filter({ inWords.contains($0) }).count >= 6 { found = true; break }
                i += 1
            }
            if !found { return false }
        }
        if segments.count > 1, let first = segments.first {
            let fw = words(first)
            if fw.count >= 3 {
                let share = Double(fw.filter { inWords.contains($0) }.count) / Double(fw.count)
                if share < 0.7 { return false }
            }
        }
        return true
    }

    // MARK: helpers

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func words(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Lines with a leading list marker (-–—*•· or N. / N)) stripped; empty lines dropped.
    static func segments(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let f = line.first, "-–—*•·".contains(f) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if let m = line.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
                line = String(line[m.upperBound...])
            }
            return line.isEmpty ? nil : line
        }
    }

    /// Folded EN/DE/FR function words from Dictus PolishGrounding.swift (ES line dropped).
    static let functionWords: Set<String> = {
        let list = """
        le la les un une des du de d au aux et ou ni mais donc or car que qui quoi dont a en y
        il elle ils elles on nous vous je tu me te se ce cet cette ces son sa ses leur leurs
        mon ma mes ton ta tes notre nos votre vos pour par avec sans sur sous dans chez vers entre
        pas ne plus tres bien tout tous toute toutes meme aussi comme si quand alors depuis apres
        avant encore deja etre avoir fait faire est sont etait ete suis es sommes etes ont as ai
        avons avez peut peux pouvoir doit dois devoir va vais aller

        the a an of to in on at for with by from as is are was were be been being and or but not no
        so if then than that this these those it its he she they we you i him her them us my your
        our their his hers do does did done have has had will would can could should may might must
        there here what which who whom when where how all any some more most very just also into
        out up down over under about

        der die das den dem des ein eine einen einem einer eines und oder aber nicht kein keine von
        zu mit auf im am an fur uber unter bei nach aus vor durch ist sind war waren sein haben hat
        habe hatte werden wird wurde ich du er wir ihr mich dich sich uns euch mein dein ihre unser
        dass wenn als auch noch nur schon sehr mehr alle alles
        """
        return Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }()
}
