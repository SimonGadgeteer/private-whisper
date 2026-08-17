using System.Text;
using System.Windows.Automation;

namespace PrivateWhisper;

/// <summary>
/// Experimental: after injecting a dictation, quietly re-read the target text
/// field a few seconds later and diff it against what was injected. Words the
/// user re-spelled (similar but changed — "Kohler"→"Koller", "Muller"→"Müller")
/// become personal-dictionary suggestions. Suggestion-only; nothing is learned
/// without a click.
///
/// Field re-read uses UI Automation (ValuePattern/TextPattern on the element
/// focused at injection time) — the Windows counterpart of the Mac AX re-read,
/// and notably more reliable, including many Electron apps. Best-effort by
/// design: unreadable fields are logged and ignored.
///
/// The diff (LCS word alignment + Levenshtein similarity) and the
/// deterministic glossary enforcement are verbatim ports of the Mac
/// CorrectionLearner algorithms — eval-verified behavior; do not "improve".
/// </summary>
public sealed class CorrectionLearner
{
    /// <summary>Fired on the UI thread with fresh suggestions (already
    /// filtered against the dictionary).</summary>
    public event Action<IReadOnlyList<string>>? OnSuggestions;

    private readonly ConfigStore configStore;
    private int generation;

    public CorrectionLearner(ConfigStore configStore)
    {
        this.configStore = configStore;
    }

    /// <summary>Call right after a successful injection, on the UI thread.</summary>
    public void Watch(string injectedText)
    {
        if (!configStore.Config.CorrectionLearningEnabled) return;
        // Too little text → too noisy to diff meaningfully.
        if (injectedText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length < 3) return;

        generation++;
        int gen = generation;
        _ = WatchAsync(injectedText, gen);
    }

    private async Task WatchAsync(string injectedText, int gen)
    {
        AutomationElement? element = await Task.Run(() =>
        {
            try { return AutomationElement.FocusedElement; }
            catch { return null; }
        });
        if (element == null)
        {
            Log.D("learner: no UIA focused element to watch");
            return;
        }

        var alreadySuggested = new HashSet<string>(StringComparer.Ordinal);

        // Keep watching across several checkpoints — the user may fix one word
        // at 8s and another at 30s. Cumulative: 8s, 20s, 35s, 60s.
        foreach (double delaySeconds in new[] { 8.0, 12.0, 15.0, 25.0 })
        {
            await Task.Delay(TimeSpan.FromSeconds(delaySeconds));
            if (gen != generation) return;
            await CheckAsync(injectedText, element, alreadySuggested);
        }
    }

    private async Task CheckAsync(
        string injectedText, AutomationElement element, HashSet<string> alreadySuggested)
    {
        string? value = await Task.Run(() => ReadTextValue(element));
        if (string.IsNullOrEmpty(value))
        {
            Log.D("learner: field value unreadable (app likely not UIA-friendly)");
            return;
        }

        var existing = new HashSet<string>(
            configStore.Config.Dictionary.Select(t => t.ToLowerInvariant()), StringComparer.Ordinal);
        var candidates = new List<string>();
        foreach (string candidate in Corrections(injectedText, value))
        {
            string lower = candidate.ToLowerInvariant();
            if (existing.Contains(lower)) continue;
            if (!alreadySuggested.Add(lower)) continue; // each new term suggested once
            candidates.Add(candidate);
        }
        if (candidates.Count == 0) return;

        Log.D("learner: suggesting " + string.Join(", ", candidates));
        OnSuggestions?.Invoke(candidates);
    }

    /// <summary>Reads the current text of a UIA element: ValuePattern first
    /// (plain fields), then TextPattern (documents/rich fields).</summary>
    private static string? ReadTextValue(AutomationElement element)
    {
        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out object valueObj) &&
                valueObj is ValuePattern valuePattern)
            {
                string v = valuePattern.Current.Value;
                if (!string.IsNullOrEmpty(v)) return v;
            }
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out object textObj) &&
                textObj is TextPattern textPattern)
            {
                string t = textPattern.DocumentRange.GetText(-1);
                if (!string.IsNullOrEmpty(t)) return t;
            }
        }
        catch
        {
            // Element vanished or app is not UIA-friendly.
        }
        return null;
    }

    // ---- Diff (verbatim port of the Mac corrections()) ----

    /// <summary>Word-aligns `original` against `edited` (which may be a whole
    /// document containing the injected text) and returns the user's
    /// respellings.</summary>
    public static IReadOnlyList<string> Corrections(string original, string edited)
    {
        List<string> originalWords = Tokenize(original);
        List<string> editedWords = Tokenize(edited);
        if (originalWords.Count == 0 || editedWords.Count > 4000) return Array.Empty<string>();

        // LCS on exact tokens anchors the unchanged words; gaps in between are
        // edit regions. Pure insertions elsewhere in the document (no original
        // counterpart) are ignored.
        List<(int O, int E)> anchors = LcsPairs(originalWords, editedWords);
        anchors.Add((originalWords.Count, editedWords.Count));

        var candidates = new List<string>();
        int prevO = -1, prevE = -1;
        foreach ((int aO, int aE) in anchors)
        {
            int gapOLength = aO - prevO - 1;
            int gapELength = aE - prevE - 1;
            int paired = Math.Min(gapOLength, gapELength);
            for (int k = 0; k < paired; k++)
            {
                string ow = originalWords[prevO + 1 + k];
                string ew = editedWords[prevE + 1 + k];
                if (ow == ew || ew.Length < 3 || !ContainsLetter(ew)) continue;
                int distance = Levenshtein(ow.ToLowerInvariant(), ew.ToLowerInvariant());
                double similarity = 1.0 - (double)distance / Math.Max(ow.Length, ew.Length);
                // A respelling of the same word: similar (incl. pure case or
                // diacritic changes, distance 0 after lowercasing).
                if (similarity >= 0.5)
                {
                    candidates.Add(ew);
                }
            }
            prevO = aO;
            prevE = aE;
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (string candidate in candidates)
        {
            if (seen.Add(candidate.ToLowerInvariant()))
            {
                result.Add(candidate);
                if (result.Count == 3) break;
            }
        }
        return result;
    }

    private static bool ContainsLetter(string s)
    {
        foreach (char c in s)
        {
            if (char.IsLetter(c)) return true;
        }
        return false;
    }

    private static bool IsWordChar(char c) =>
        char.IsLetterOrDigit(c) || c == '-' || c == '\'' || c == '’';

    private static List<string> Tokenize(string text)
    {
        var tokens = new List<string>();
        foreach (string raw in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            // Trim leading/trailing chars that are not letters/digits/-'’
            // (mirror of the Mac trimmingCharacters set).
            int start = 0;
            int end = raw.Length - 1;
            while (start <= end && !IsWordChar(raw[start])) start++;
            while (end >= start && !IsWordChar(raw[end])) end--;
            if (end >= start)
            {
                tokens.Add(raw.Substring(start, end - start + 1));
            }
        }
        return tokens;
    }

    /// <summary>Indices of matching (original, edited) word pairs via classic LCS.</summary>
    private static List<(int, int)> LcsPairs(List<string> a, List<string> b)
    {
        int n = a.Count, m = b.Count;
        var table = new int[n + 1, m + 1];
        for (int i = n - 1; i >= 0; i--)
        {
            for (int j = m - 1; j >= 0; j--)
            {
                table[i, j] = a[i] == b[j]
                    ? table[i + 1, j + 1] + 1
                    : Math.Max(table[i + 1, j], table[i, j + 1]);
            }
        }
        var pairs = new List<(int, int)>();
        int x = 0, y = 0;
        while (x < n && y < m)
        {
            if (a[x] == b[y])
            {
                pairs.Add((x, y));
                x++;
                y++;
            }
            else if (table[x + 1, y] >= table[x, y + 1])
            {
                x++;
            }
            else
            {
                y++;
            }
        }
        return pairs;
    }

    // ---- Deterministic glossary enforcement (verbatim port) ----

    /// <summary>Replaces output words that are near-misses of a dictionary term
    /// (similarity ≥ 0.8, length ≥ 4) with the exact dictionary spelling. Runs
    /// after cleanup so a term ALWAYS wins even when whisper and the LLM both
    /// fumble it.</summary>
    public static string EnforceDictionary(string text, IReadOnlyList<string> dictionary)
    {
        if (dictionary.Count == 0) return text;
        var terms = dictionary.Where(t => t.Length >= 4).ToList();
        if (terms.Count == 0) return text;

        var result = new StringBuilder(text.Length);
        var word = new StringBuilder();

        void Flush()
        {
            if (word.Length > 0)
            {
                result.Append(Replacement(word.ToString(), terms));
                word.Clear();
            }
        }

        foreach (char ch in text)
        {
            if (char.IsLetter(ch) || ch == '-' || ch == '\'' || ch == '’')
            {
                word.Append(ch);
            }
            else
            {
                Flush();
                result.Append(ch);
            }
        }
        Flush();
        return result.ToString();
    }

    private static string Replacement(string word, List<string> terms)
    {
        if (word.Length < 4) return word;
        string lower = word.ToLowerInvariant();
        foreach (string term in terms)
        {
            string termLower = term.ToLowerInvariant();
            if (lower == termLower) return term; // case/diacritic-exact enforcement
            int distance = Levenshtein(lower, termLower);
            double similarity = 1.0 - (double)distance / Math.Max(word.Length, term.Length);
            if (similarity >= 0.8) return term;
        }
        return word;
    }

    /// <summary>Two-row Levenshtein distance (verbatim port).</summary>
    public static int Levenshtein(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var previous = new int[b.Length + 1];
        var current = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) previous[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            current[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                current[j] = Math.Min(
                    Math.Min(previous[j] + 1, current[j - 1] + 1),
                    previous[j - 1] + cost);
            }
            (previous, current) = (current, previous);
        }
        return previous[b.Length];
    }
}
