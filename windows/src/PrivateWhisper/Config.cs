using System.Text.Json;
using Microsoft.Win32;

namespace PrivateWhisper;

/// <summary>Hotkey identifiers stored in config.json (tolerant strings, not a
/// brittle enum — unknown values fall back to the default).</summary>
public static class Hotkeys
{
    public const string RightAlt = "rightAlt";
    public const string LeftAlt = "leftAlt";
    public const string RightCtrl = "rightCtrl";
    public const string RightShift = "rightShift";

    /// <summary>(id, label) pairs for the settings dropdowns.</summary>
    public static readonly (string Id, string Label)[] All =
    {
        (RightAlt, "Right Alt"),
        (LeftAlt, "Left Alt"),
        (RightCtrl, "Right Ctrl"),
        (RightShift, "Right Shift"),
    };

    public static uint VirtualKey(string? choice) => choice switch
    {
        RightAlt => NativeMethods.VK_RMENU,
        LeftAlt => NativeMethods.VK_LMENU,
        RightCtrl => NativeMethods.VK_RCONTROL,
        RightShift => NativeMethods.VK_RSHIFT,
        _ => NativeMethods.VK_RMENU,
    };

    public static string Label(string? choice)
    {
        foreach (var (id, label) in All)
        {
            if (id == choice) return label;
        }
        return "Right Alt";
    }
}

/// <summary>
/// App configuration, persisted as JSON. Mirrors the Mac AppConfig.
///
/// Portable mode (windows-port-analysis.md §3): if portable.marker or
/// config.json sits next to the exe, ALL data (config, models, stats, log)
/// stays in the app folder; otherwise everything lives in
/// %APPDATA%\PrivateWhisper. Decided once at startup.
/// </summary>
public sealed class AppConfig
{
    // ---- Fields (mirror Mac AppConfig) ----

    /// <summary>Hold-to-talk dictation key. Default Right Alt (VK_RMENU).</summary>
    public string Hotkey { get; set; } = Hotkeys.RightAlt;

    /// <summary>MMDevice ID of the capture device; null = system default.</summary>
    public string? MicrophoneDeviceId { get; set; }

    /// <summary>"large-v3-turbo" or "large-v3" — resolved to ggml-&lt;name&gt;.bin.</summary>
    public string WhisperModel { get; set; } = "large-v3-turbo";

    public string LmStudioUrl { get; set; } = "http://localhost:1234/v1";

    public string CleanupModel { get; set; } = "qwen/qwen3.5-4b";

    public bool CleanupEnabled { get; set; } = true;

    public double CleanupTimeoutSeconds { get; set; } = 15;

    public bool HistoryLoggingEnabled { get; set; }

    public bool LaunchAtLogin { get; set; }

    /// <summary>Windows counterpart of the Mac notch capsule toggle.</summary>
    public bool OverlayEnabled { get; set; } = true;

    /// <summary>Stored overlay position (virtual-screen DIP coordinates).
    /// null = default top-center of the primary display.</summary>
    public double? OverlayX { get; set; }
    public double? OverlayY { get; set; }

    /// <summary>Personal dictionary: names/jargon biased into whisper and
    /// enforced in cleanup.</summary>
    public List<string> Dictionary { get; set; } = new();

    /// <summary>Foreground process name (lowercase, incl. ".exe") → tone hint
    /// appended to the cleanup prompt. Windows analog of Mac bundle IDs.</summary>
    public Dictionary<string, string> AppTones { get; set; } = DefaultAppTones();

    /// <summary>Hold-to-speak hotkey for command mode (voice-edit the current
    /// selection). null = disabled. Default Right Ctrl.</summary>
    public string? CommandHotkey { get; set; } = Hotkeys.RightCtrl;

    /// <summary>Experimental: diff the target field after injection and suggest
    /// dictionary terms from the user's manual respellings.</summary>
    public bool CorrectionLearningEnabled { get; set; } = true;

    public static Dictionary<string, string> DefaultAppTones() => new()
    {
        ["outlook.exe"] = "formal email register",
        ["olk.exe"] = "formal email register",
        ["thunderbird.exe"] = "formal email register",
        ["slack.exe"] = "casual chat register",
        ["ms-teams.exe"] = "professional chat register",
        ["teams.exe"] = "professional chat register",
        ["code.exe"] = "technical, keep identifiers and code terms verbatim",
    };

    // ---- Locations ----

    public static string BaseDir => AppContext.BaseDirectory;

    /// <summary>Decided once per process: marker or config next to the exe = portable.</summary>
    public static readonly bool IsPortable =
        File.Exists(Path.Combine(AppContext.BaseDirectory, "portable.marker")) ||
        File.Exists(Path.Combine(AppContext.BaseDirectory, "config.json"));

    public static string SupportDir => IsPortable
        ? BaseDir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PrivateWhisper");

    public static string ConfigPath => Path.Combine(SupportDir, "config.json");
    public static string ModelsDir => Path.Combine(SupportDir, "models");
    public static string HistoryPath => Path.Combine(SupportDir, "history.jsonl");
    public static string LogPath => Path.Combine(SupportDir, "app.log");

    public string WhisperModelPath => Path.Combine(ModelsDir, $"ggml-{WhisperModel}.bin");

    // ---- Persistence (tolerant JSON: unknown keys ignored, missing keys keep
    // defaults, a corrupt file falls back to defaults) ----

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                string json = File.ReadAllText(ConfigPath);
                AppConfig? config = JsonSerializer.Deserialize<AppConfig>(json, JsonOptions);
                if (config != null) return config;
            }
        }
        catch (Exception ex)
        {
            Log.D("config load failed, using defaults: " + ex.Message);
        }
        return new AppConfig();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SupportDir);
            string json = JsonSerializer.Serialize(this, JsonOptions);
            File.WriteAllText(ConfigPath, json);
        }
        catch (Exception ex)
        {
            Log.D("config save failed: " + ex.Message);
        }
    }
}

/// <summary>Shared config wrapper so windows and the pipeline see one instance
/// (the Mac ConfigStore). Mutations go through Update() so every change is
/// saved and observers are notified.</summary>
public sealed class ConfigStore
{
    public AppConfig Config { get; }

    public event Action? Changed;

    public ConfigStore()
    {
        Config = AppConfig.Load();
    }

    public void Update(Action<AppConfig> mutate)
    {
        mutate(Config);
        Config.Save();
        Changed?.Invoke();
    }
}

/// <summary>HKCU Run key — user-scoped launch at login, no admin required.</summary>
public static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "PrivateWhisper";

    public static void Apply(bool enabled)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (key == null) return;
            if (enabled)
            {
                string? exe = Environment.ProcessPath;
                if (exe != null) key.SetValue(ValueName, "\"" + exe + "\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            Log.D("launch-at-login registry update failed: " + ex.Message);
        }
    }
}
