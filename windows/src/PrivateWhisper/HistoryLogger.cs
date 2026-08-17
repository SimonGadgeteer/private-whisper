using System.Text.Json;

namespace PrivateWhisper;

/// <summary>
/// Optional JSONL history of dictations — only written when the user turns
/// history logging on (off by default; transcripts are sensitive).
/// </summary>
public static class HistoryLogger
{
    public sealed record Entry(
        string Timestamp,
        string Language,
        string RawTranscript,
        string? CleanedText,
        double AudioSeconds,
        double TranscriptionSeconds,
        double? CleanupSeconds);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static readonly object Sync = new();

    public static void Append(Entry entry)
    {
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(AppConfig.SupportDir);
                File.AppendAllText(
                    AppConfig.HistoryPath,
                    JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine);
            }
        }
        catch (Exception ex)
        {
            Log.D("history append failed: " + ex.Message);
        }
    }
}
