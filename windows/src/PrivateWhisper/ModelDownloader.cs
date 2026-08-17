using System.Text.Json;

namespace PrivateWhisper;

/// <summary>Model catalog parsed from the shared, embedded model_manifest.json
/// (single source of truth across platforms — model choices are eval-verified).
/// Whisper entries keep their manifest keys ("large-v3-turbo", "large-v3");
/// the cleanup LLM is exposed under the key "cleanup-llm" like on the Mac.</summary>
public static class ModelManifest
{
    public sealed record Entry(string Key, string Url, string FileName, string Size, string Label, bool Required);

    public static readonly IReadOnlyDictionary<string, Entry> Items = Load();

    private static Dictionary<string, Entry> Load()
    {
        var items = new Dictionary<string, Entry>();
        using JsonDocument doc = JsonDocument.Parse(EmbeddedResources.ReadText("model_manifest.json"));

        if (doc.RootElement.TryGetProperty("whisper", out JsonElement whisper))
        {
            foreach (JsonProperty prop in whisper.EnumerateObject())
            {
                items[prop.Name] = Parse(prop.Name, prop.Value,
                    $"Transcription model (Whisper {prop.Name})");
            }
        }
        if (doc.RootElement.TryGetProperty("cleanup", out JsonElement cleanup))
        {
            foreach (JsonProperty prop in cleanup.EnumerateObject())
            {
                items["cleanup-llm"] = Parse("cleanup-llm", prop.Value,
                    "Cleanup model (Qwen 3.5 4B, embedded)");
                break; // single cleanup model
            }
        }
        return items;
    }

    private static Entry Parse(string key, JsonElement el, string label) => new(
        key,
        el.GetProperty("url").GetString() ?? "",
        el.GetProperty("file").GetString() ?? "",
        el.TryGetProperty("size", out JsonElement size) ? size.GetString() ?? "" : "",
        label,
        el.TryGetProperty("required", out JsonElement required) && required.GetBoolean());
}

/// <summary>
/// Downloads model weights into the models dir on first run, so the app can be
/// distributed without bundling gigabytes. Multiple items with per-item
/// progress (whisper models + the embedded cleanup LLM). Port of the Mac
/// ModelDownloader (HttpClient streaming instead of URLSession delegates).
/// </summary>
public sealed class ModelDownloader
{
    public static readonly ModelDownloader Shared = new();

    public sealed record DownloadState(bool Downloading, double Progress, string? Error);

    /// <summary>Raised on a background thread — marshal to the UI thread
    /// before touching WPF.</summary>
    public event Action<string, DownloadState>? StateChanged;

    private readonly Dictionary<string, DownloadState> states = new();
    private readonly object sync = new();

    private static readonly HttpClient Http = new() { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    public static bool IsInstalled(string key) =>
        ModelManifest.Items.TryGetValue(key, out ModelManifest.Entry? item) &&
        File.Exists(Path.Combine(AppConfig.ModelsDir, item.FileName));

    public DownloadState GetState(string key)
    {
        lock (sync)
        {
            return states.TryGetValue(key, out DownloadState? state)
                ? state
                : new DownloadState(false, 0, null);
        }
    }

    public void Download(string key)
    {
        if (!ModelManifest.Items.TryGetValue(key, out ModelManifest.Entry? item)) return;
        lock (sync)
        {
            if (states.TryGetValue(key, out DownloadState? state) && state.Downloading) return;
            states[key] = new DownloadState(true, 0, null);
        }
        StateChanged?.Invoke(key, new DownloadState(true, 0, null));
        _ = Task.Run(() => DownloadCoreAsync(key, item));
    }

    private async Task DownloadCoreAsync(string key, ModelManifest.Entry item)
    {
        try
        {
            Directory.CreateDirectory(AppConfig.ModelsDir);
            string destination = Path.Combine(AppConfig.ModelsDir, item.FileName);
            string partial = destination + ".part";

            using HttpResponseMessage response = await Http.GetAsync(
                item.Url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            long total = response.Content.Headers.ContentLength ?? -1;

            await using (Stream input = await response.Content.ReadAsStreamAsync())
            await using (var output = new FileStream(
                partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                var buffer = new byte[1 << 16];
                long written = 0;
                double lastReported = 0;
                int read;
                while ((read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length))) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read));
                    written += read;
                    if (total > 0)
                    {
                        double fraction = (double)written / total;
                        if (fraction - lastReported >= 0.005)
                        {
                            lastReported = fraction;
                            Set(key, new DownloadState(true, fraction, null));
                        }
                    }
                }
            }

            File.Move(partial, destination, overwrite: true);
            Set(key, new DownloadState(false, 1, null));
            Log.D("Model downloaded: " + item.FileName);
        }
        catch (Exception ex)
        {
            Log.D($"model download failed ({key}): {ex.Message}");
            Set(key, new DownloadState(false, 0, ex.Message));
        }
    }

    private void Set(string key, DownloadState state)
    {
        lock (sync)
        {
            states[key] = state;
        }
        StateChanged?.Invoke(key, state);
    }
}
