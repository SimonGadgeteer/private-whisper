import AppKit

/// Experimental: after injecting a dictation, quietly re-read the target text
/// field a few seconds later and diff it against what was injected. Words the
/// user re-spelled (similar but changed — "Kohler"→"Koller", "Muller"→"Müller")
/// become personal-dictionary suggestions. Suggestion-only; nothing is learned
/// without a click.
///
/// Best-effort by design: reading a field back via AX works in native apps and
/// silently fails in many Electron/web views — failures are logged (app.log)
/// and otherwise ignored.
@MainActor
final class CorrectionLearner {
    /// Fired with fresh suggestions (already filtered against the dictionary).
    var onSuggestions: (([String]) -> Void)?

    private let configStore: ConfigStore
    private var generation = 0

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// Call right after a successful injection.
    func watch(injected text: String) {
        guard configStore.config.correctionLearningEnabled else { return }
        // Too little text → too noisy to diff meaningfully.
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return }
        guard let element = Self.focusedElement() else {
            dlog("learner: no AX focused element to watch")
            return
        }
        generation += 1
        let gen = generation

        Task { [weak self] in
            for delaySeconds in [10.0, 25.0] {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard let self, gen == self.generation else { return }
                if self.check(injected: text, element: element) { return }
            }
        }
    }

    /// Returns true when suggestions were produced (stops further checks).
    private func check(injected text: String, element: AXUIElement) -> Bool {
        guard let value = Self.stringValue(of: element) else {
            dlog("learner: field value unreadable (app likely not AX-friendly)")
            return false
        }
        let existing = Set(configStore.config.dictionary.map { $0.lowercased() })
        let candidates = Self.corrections(original: text, edited: value)
            .filter { !existing.contains($0.lowercased()) }
        guard !candidates.isEmpty else { return false }
        dlog("learner: suggesting \(candidates)")
        onSuggestions?(candidates)
        return true
    }

    // MARK: - AX plumbing

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // MARK: - Diff

    /// Word-aligns `original` against `edited` (which may be a whole document
    /// containing the injected text) and returns the user's respellings.
    nonisolated static func corrections(original: String, edited: String) -> [String] {
        let originalWords = tokenize(original)
        let editedWords = tokenize(edited)
        guard !originalWords.isEmpty, editedWords.count <= 4000 else { return [] }

        // LCS on exact tokens anchors the unchanged words; gaps in between are
        // edit regions. Pure insertions elsewhere in the document (no original
        // counterpart) are ignored.
        let anchors = lcsPairs(originalWords, editedWords)

        var candidates: [String] = []
        var prevO = -1, prevE = -1
        for (aO, aE) in anchors + [(originalWords.count, editedWords.count)] {
            let gapO = originalWords[(prevO + 1)..<aO]
            let gapE = editedWords[(prevE + 1)..<aE]
            for (ow, ew) in zip(gapO, gapE) {
                guard ow != ew, ew.count >= 3, ew.rangeOfCharacter(from: .letters) != nil
                else { continue }
                let distance = levenshtein(ow.lowercased(), ew.lowercased())
                let similarity = 1.0 - Double(distance) / Double(max(ow.count, ew.count))
                // A respelling of the same word: similar (incl. pure case or
                // diacritic changes, distance 0 after lowercasing).
                if similarity >= 0.5 {
                    candidates.append(ew)
                }
            }
            prevO = aO
            prevE = aE
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }.prefix(3).map { $0 }
    }

    nonisolated private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(
                CharacterSet(charactersIn: "-'’")))
        }.filter { !$0.isEmpty }
    }

    /// Indices of matching (original, edited) word pairs via classic LCS.
    nonisolated private static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    nonisolated private static func levenshtein(_ a: String, _ b: String) -> Int {
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
