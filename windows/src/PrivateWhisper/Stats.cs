using System.Text.Json;

namespace PrivateWhisper;

/// <summary>
/// Aggregate usage statistics — counters only, no transcript content (full
/// transcripts are stored only when history logging is explicitly enabled).
/// Field-for-field port of the Mac DictationStats.
/// </summary>
public sealed class DictationStats
{
    public int TotalDictations { get; set; }
    public int TotalWords { get; set; }
    public double TotalAudioSeconds { get; set; }
    public double TotalTranscriptionSeconds { get; set; }
    public double TotalCleanupSeconds { get; set; }
    public int CleanupFallbacks { get; set; }

    /// <summary>ISO language code → dictation count.</summary>
    public Dictionary<string, int> ByLanguage { get; set; } = new();

    /// <summary>"yyyy-MM-dd" → dictation count (kept to the last 60 days).</summary>
    public Dictionary<string, int> ByDay { get; set; } = new();

    public double AverageLatency =>
        TotalDictations > 0
            ? (TotalTranscriptionSeconds + TotalCleanupSeconds) / TotalDictations
            : 0;
}

public sealed class StatsStore
{
    public static readonly StatsStore Shared = new();

    public DictationStats Stats { get; private set; }

    public event Action? Changed;

    private static string FilePath => Path.Combine(AppConfig.SupportDir, "stats.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private StatsStore()
    {
        Stats = LoadFromDisk();
    }

    private static DictationStats LoadFromDisk()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var loaded = JsonSerializer.Deserialize<DictationStats>(File.ReadAllText(FilePath), JsonOptions);
                if (loaded != null) return loaded;
            }
        }
        catch (Exception ex)
        {
            Log.D("stats load failed: " + ex.Message);
        }
        return new DictationStats();
    }

    public void Record(
        int words, string language, double audioSeconds,
        double transcriptionSeconds, double? cleanupSeconds, bool fellBack)
    {
        Stats.TotalDictations += 1;
        Stats.TotalWords += words;
        Stats.TotalAudioSeconds += audioSeconds;
        Stats.TotalTranscriptionSeconds += transcriptionSeconds;
        Stats.TotalCleanupSeconds += cleanupSeconds ?? 0;
        if (fellBack) Stats.CleanupFallbacks += 1;

        Stats.ByLanguage.TryGetValue(language, out int langCount);
        Stats.ByLanguage[language] = langCount + 1;

        string today = DateTime.Now.ToString("yyyy-MM-dd");
        Stats.ByDay.TryGetValue(today, out int dayCount);
        Stats.ByDay[today] = dayCount + 1;
        if (Stats.ByDay.Count > 60)
        {
            foreach (string key in Stats.ByDay.Keys.OrderBy(k => k, StringComparer.Ordinal)
                         .Take(Stats.ByDay.Count - 60).ToList())
            {
                Stats.ByDay.Remove(key);
            }
        }

        Save();
        Changed?.Invoke();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(AppConfig.SupportDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(Stats, JsonOptions));
        }
        catch (Exception ex)
        {
            Log.D("stats save failed: " + ex.Message);
        }
    }
}
