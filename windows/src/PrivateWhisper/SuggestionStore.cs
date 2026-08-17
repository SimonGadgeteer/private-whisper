namespace PrivateWhisper;

/// <summary>Pending dictionary suggestions from the correction learner.
/// Suggestion-only: nothing enters the dictionary without a click in the
/// Dictionary window.</summary>
public static class SuggestionStore
{
    private static readonly List<string> Pending = new();
    private static readonly object Sync = new();

    public static event Action? Changed;

    public static IReadOnlyList<string> Items
    {
        get
        {
            lock (Sync) return Pending.ToList();
        }
    }

    public static void Add(IEnumerable<string> terms)
    {
        bool changed = false;
        lock (Sync)
        {
            foreach (string term in terms)
            {
                if (!Pending.Contains(term, StringComparer.OrdinalIgnoreCase))
                {
                    Pending.Add(term);
                    changed = true;
                }
            }
        }
        if (changed) Changed?.Invoke();
    }

    public static void Remove(string term)
    {
        lock (Sync)
        {
            Pending.RemoveAll(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase));
        }
        Changed?.Invoke();
    }
}
