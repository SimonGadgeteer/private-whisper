using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PrivateWhisper;

public sealed record TranscriptionResult(string Text, string Language);

public sealed class TranscriberException : Exception
{
    public TranscriberException(string message) : base(message) { }
}

/// <summary>
/// Transcribes via the whisper-server sidecar's HTTP API.
///
/// Endpoint (verified against ggml-org/whisper.cpp examples/server/server.cpp):
///   POST /inference, multipart/form-data with fields:
///     file                       — the audio (a standard WAV works without ffmpeg)
///     language=auto              — whisper auto-detects the spoken language
///     response_format=verbose_json — response carries "text" AND "language"
///     no_language_probabilities=true — skip the expensive per-language probe;
///                                  the top-level "language" field remains
///     temperature=0.0
///     prompt=&lt;dictionary terms&gt; — biases recognition toward these spellings
///                                  (same initial_prompt trick as the Mac app)
///   Response: {"task","language","duration","text","segments":[...]}
///   ("language" is whisper's full name, e.g. "english" — mapped to ISO codes
///   below for parity with the Mac stats/prompt).
/// </summary>
public sealed class WhisperServerTranscriber
{
    private static readonly HttpClient Http = new() { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    private readonly WhisperSidecar sidecar;

    public WhisperServerTranscriber(WhisperSidecar sidecar)
    {
        this.sidecar = sidecar;
    }

    /// <summary>vocabulary biases recognition toward personal-dictionary terms.</summary>
    public async Task<TranscriptionResult> TranscribeAsync(float[] samples, IReadOnlyList<string> vocabulary)
    {
        string? baseUrl = await sidecar.EnsureRunningAsync();
        if (baseUrl == null)
        {
            throw new TranscriberException(
                "whisper-server unavailable (model not downloaded, or runtime\\whisper\\whisper-server.exe missing)");
        }

        byte[] wav = EncodeWav16kMono16Bit(samples);

        using var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(wav);
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(file, "file", "audio.wav");
        form.Add(new StringContent("auto"), "language");
        form.Add(new StringContent("verbose_json"), "response_format");
        form.Add(new StringContent("true"), "no_language_probabilities");
        form.Add(new StringContent("0.0"), "temperature");
        if (vocabulary.Count > 0)
        {
            // Cap like the Mac app (stay within n_ctx/2).
            form.Add(new StringContent(string.Join(", ", vocabulary.Take(80))), "prompt");
        }

        string body;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(300));
            using HttpResponseMessage response = await Http.PostAsync(baseUrl + "/inference", form, cts.Token);
            body = await response.Content.ReadAsStringAsync(cts.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw new TranscriberException(
                    $"whisper-server HTTP {(int)response.StatusCode}: {Truncate(body, 300)}");
            }
        }
        catch (TranscriberException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new TranscriberException("whisper-server request failed: " + ex.Message);
        }

        string text;
        string language;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(body);
            text = doc.RootElement.TryGetProperty("text", out JsonElement t) ? t.GetString() ?? "" : "";
            language = doc.RootElement.TryGetProperty("language", out JsonElement l)
                ? l.GetString() ?? "unknown"
                : "unknown";
        }
        catch (JsonException)
        {
            throw new TranscriberException("whisper-server returned unexpected response: " + Truncate(body, 200));
        }

        return new TranscriptionResult(CleanRawTranscript(text), ToIsoCode(language));
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    /// <summary>Removes whisper artifacts like "[BLANK_AUDIO]", "(wind blowing)"
    /// and trims whitespace. Returns "" when nothing meaningful was heard.
    /// Port of the Mac cleanRawTranscript.</summary>
    public static string CleanRawTranscript(string raw)
    {
        string text = raw;
        text = Regex.Replace(text, @"\[[^\]]*\]", "");
        text = Regex.Replace(text, @"\([^)]*\)", "");
        text = Regex.Replace(text, "♪[^♪]*♪", "");
        text = Regex.Replace(text, @"\s+", " ").Trim();
        // Only punctuation left → treat as silence.
        bool hasAlphanumeric = false;
        foreach (char c in text)
        {
            if (char.IsLetterOrDigit(c)) { hasAlphanumeric = true; break; }
        }
        return hasAlphanumeric ? text : "";
    }

    /// <summary>16 kHz mono 16-bit PCM WAV — the most universally decodable
    /// input for whisper-server (no ffmpeg needed server-side).</summary>
    public static byte[] EncodeWav16kMono16Bit(float[] samples)
    {
        int dataLength = samples.Length * 2;
        using var ms = new MemoryStream(44 + dataLength);
        using (var writer = new BinaryWriter(ms, Encoding.ASCII, leaveOpen: true))
        {
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + dataLength);
            writer.Write(Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(Encoding.ASCII.GetBytes("fmt "));
            writer.Write(16);              // fmt chunk size
            writer.Write((short)1);        // PCM
            writer.Write((short)1);        // mono
            writer.Write(16000);           // sample rate
            writer.Write(16000 * 2);       // byte rate
            writer.Write((short)2);        // block align
            writer.Write((short)16);       // bits per sample
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write(dataLength);
            foreach (float sample in samples)
            {
                float clamped = Math.Clamp(sample, -1f, 1f);
                writer.Write((short)Math.Round(clamped * 32767f));
            }
        }
        return ms.ToArray();
    }

    /// <summary>whisper-server reports the full language name (whisper_lang_str_full);
    /// map to ISO 639-1 for parity with the Mac app's stats keys and the
    /// cleanup prompt's language line. Unknown names pass through lowercased.</summary>
    public static string ToIsoCode(string? whisperLanguage)
    {
        if (string.IsNullOrEmpty(whisperLanguage)) return "unknown";
        return LanguageCodes.TryGetValue(whisperLanguage, out string? code)
            ? code
            : whisperLanguage.ToLowerInvariant();
    }

    private static readonly Dictionary<string, string> LanguageCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["english"] = "en",
        ["german"] = "de",
        ["french"] = "fr",
        ["italian"] = "it",
        ["spanish"] = "es",
        ["portuguese"] = "pt",
        ["dutch"] = "nl",
        ["polish"] = "pl",
        ["russian"] = "ru",
        ["japanese"] = "ja",
        ["chinese"] = "zh",
        ["korean"] = "ko",
        ["arabic"] = "ar",
        ["turkish"] = "tr",
        ["swedish"] = "sv",
        ["danish"] = "da",
        ["norwegian"] = "no",
        ["finnish"] = "fi",
        ["czech"] = "cs",
        ["greek"] = "el",
        ["hungarian"] = "hu",
        ["romanian"] = "ro",
        ["ukrainian"] = "uk",
        ["catalan"] = "ca",
        ["hebrew"] = "he",
        ["hindi"] = "hi",
        ["thai"] = "th",
        ["vietnamese"] = "vi",
        ["indonesian"] = "id",
        ["malay"] = "ms",
        ["slovak"] = "sk",
        ["slovenian"] = "sl",
        ["croatian"] = "hr",
        ["serbian"] = "sr",
        ["bulgarian"] = "bg",
        ["lithuanian"] = "lt",
        ["latvian"] = "lv",
        ["estonian"] = "et",
        ["tagalog"] = "tl",
        ["urdu"] = "ur",
    };
}
