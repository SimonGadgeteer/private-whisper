using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PrivateWhisper;

/// <summary>
/// Talks to an OpenAI-compatible /chat/completions endpoint (LM Studio or the
/// embedded llama-server) for the cleanup pass and command-mode rewrites.
/// Any failure throws — the pipeline falls back to the raw transcript so
/// dictation is never lost. Logic ported 1:1 from the Mac CleanupService;
/// the prompts come from the shared, eval-verified resources.
/// </summary>
public sealed class CleanupService
{
    private static readonly HttpClient Http = new() { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    public string BaseUrl { get; }
    public string Model { get; }
    public double TimeoutSeconds { get; }

    public CleanupService(string baseUrl, string model, double timeoutSeconds)
    {
        BaseUrl = baseUrl;
        Model = model;
        TimeoutSeconds = timeoutSeconds;
    }

    /// <summary>Canonical prompt from shared/prompts/cleanup_prompt.txt.</summary>
    public static readonly string SystemPrompt = EmbeddedResources.ReadText("cleanup_prompt.txt");

    /// <summary>Canonical prompt from shared/prompts/rewrite_prompt.txt.</summary>
    public static readonly string RewritePrompt = EmbeddedResources.ReadText("rewrite_prompt.txt");

    public sealed class CleanupException : Exception
    {
        public CleanupException(string message) : base(message) { }
    }

    public async Task<string> CleanupAsync(
        string transcript, string? language,
        IReadOnlyList<string> glossary, string? toneHint)
    {
        var systemPrompt = new StringBuilder(SystemPrompt);
        if (!string.IsNullOrEmpty(language) && language != "unknown")
        {
            systemPrompt.Append($"\n- The input language is \"{language}\". The output must be in that same language.");
        }
        if (glossary.Count > 0)
        {
            systemPrompt.Append("\n- Personal dictionary — when the transcript contains a similar-sounding or misspelled variant of one of these, use this exact spelling: ")
                .Append(string.Join(", ", glossary));
        }
        if (!string.IsNullOrEmpty(toneHint))
        {
            systemPrompt.Append($"\n- The text will be inserted into an app where the expected style is: {toneHint}. Adjust register lightly; never change meaning.");
        }

        // PRD: max_tokens sized to input length × 1.5 (≈3 chars/token heuristic),
        // plus fixed headroom for reasoning models that "think" before answering —
        // otherwise they hit the cap mid-thought and return empty content.
        // Non-thinking models just stop early, so the headroom is free.
        int maxTokens = Math.Max(256, (int)(transcript.Length / 3.0 * 1.5) + 64) + 2048;

        return await SendAsync(systemPrompt.ToString(), transcript, maxTokens);
    }

    /// <summary>Command mode: apply a spoken instruction to selected text.</summary>
    public async Task<string> RewriteAsync(string selection, string instruction)
    {
        string user = $"Instruction: {instruction}\n\nText:\n{selection}";
        int maxTokens = Math.Max(512, (int)(selection.Length / 3.0 * 2)) + 2048;
        return await SendAsync(RewritePrompt, user, maxTokens);
    }

    private async Task<string> SendAsync(string systemPrompt, string userContent, int maxTokens)
    {
        string url = BaseUrl.Trim('/') + "/chat/completions";

        // Qwen3 hybrids honor /no_think in the prompt; belt-and-braces next to
        // reasoning_effort below. Harmless elsewhere.
        if (Model.Contains("qwen", StringComparison.OrdinalIgnoreCase))
        {
            systemPrompt += "\n/no_think";
        }

        var body = new JsonObject
        {
            ["model"] = Model,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = systemPrompt },
                new JsonObject { ["role"] = "user", ["content"] = userContent }),
            ["temperature"] = 0.2,
            ["max_tokens"] = maxTokens,
            ["stream"] = false,
            // Disables thinking on models that support it (e.g. Qwen 3.5 —
            // 0.46s instead of 67s); safely ignored by non-reasoning models.
            ["reasoning_effort"] = "none",
        };

        string responseBody;
        try
        {
            using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(TimeoutSeconds));
            using HttpResponseMessage response = await Http.PostAsync(url, content, cts.Token);
            responseBody = await response.Content.ReadAsStringAsync(cts.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw new CleanupException(
                    $"Cleanup backend error: HTTP {(int)response.StatusCode} {Truncate(responseBody, 300)}");
            }
        }
        catch (CleanupException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new CleanupException("Cleanup request failed: " + ex.Message);
        }

        string? messageContent = null;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(responseBody);
            if (doc.RootElement.TryGetProperty("choices", out JsonElement choices) &&
                choices.ValueKind == JsonValueKind.Array && choices.GetArrayLength() > 0 &&
                choices[0].TryGetProperty("message", out JsonElement message) &&
                message.TryGetProperty("content", out JsonElement contentEl))
            {
                messageContent = contentEl.GetString();
            }
        }
        catch (JsonException)
        {
            // handled below
        }
        if (messageContent == null)
        {
            throw new CleanupException("Cleanup backend returned an unexpected response shape");
        }

        string cleaned = StripReasoning(messageContent).Trim();
        if (cleaned.Length == 0)
        {
            throw new CleanupException("Cleanup backend returned an empty result");
        }
        return cleaned;
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    /// <summary>Removes &lt;think&gt;…&lt;/think&gt; blocks that reasoning models may emit.</summary>
    public static string StripReasoning(string text)
    {
        string result = Regex.Replace(text, "<think>.*?</think>", "", RegexOptions.Singleline);
        // Unterminated think block (hit max_tokens mid-reasoning) → nothing usable.
        int open = result.IndexOf("<think>", StringComparison.Ordinal);
        if (open >= 0)
        {
            result = result[..open];
        }
        return result;
    }

    /// <summary>Fetches available model IDs from LM Studio (settings dropdown).</summary>
    public static async Task<IReadOnlyList<string>> AvailableModelsAsync(string baseUrl)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            using HttpResponseMessage response = await Http.GetAsync(baseUrl.Trim('/') + "/models", cts.Token);
            string body = await response.Content.ReadAsStringAsync(cts.Token);
            using JsonDocument doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("data", out JsonElement data) &&
                data.ValueKind == JsonValueKind.Array)
            {
                var models = new List<string>();
                foreach (JsonElement item in data.EnumerateArray())
                {
                    if (item.TryGetProperty("id", out JsonElement id) && id.GetString() is string s)
                    {
                        models.Add(s);
                    }
                }
                return models;
            }
        }
        catch
        {
            // unreachable → empty list
        }
        return Array.Empty<string>();
    }

    // ---- Backend routing (port of the Mac resolveBackend) ----

    /// <summary>Quick reachability probe with a short cache (avoids a 1 s stall
    /// on every dictation when LM Studio is down).</summary>
    private static (string Url, bool Reachable, DateTime At)? lastProbe;
    private static readonly object ProbeLock = new();

    public static async Task<bool> IsReachableAsync(string baseUrl)
    {
        lock (ProbeLock)
        {
            if (lastProbe is { } probe && probe.Url == baseUrl &&
                (DateTime.UtcNow - probe.At).TotalSeconds < 30)
            {
                return probe.Reachable;
            }
        }
        bool reachable;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            using HttpResponseMessage response = await Http.GetAsync(baseUrl.Trim('/') + "/models", cts.Token);
            reachable = true; // any HTTP response counts, like the Mac probe
        }
        catch
        {
            reachable = false;
        }
        lock (ProbeLock)
        {
            lastProbe = (baseUrl, reachable, DateTime.UtcNow);
        }
        return reachable;
    }

    /// <summary>Backend resolution: LM Studio (local or remote Mac Mini) first,
    /// then the embedded llama-server sidecar, else null (caller falls back to
    /// the raw transcript).</summary>
    public static async Task<(string BaseUrl, string Model)?> ResolveBackendAsync(
        AppConfig config, LlamaSidecar embedded)
    {
        if (await IsReachableAsync(config.LmStudioUrl))
        {
            return (config.LmStudioUrl, config.CleanupModel);
        }
        string? embeddedUrl = await embedded.EnsureRunningAsync();
        if (embeddedUrl != null)
        {
            return (embeddedUrl, "embedded");
        }
        return null;
    }
}
