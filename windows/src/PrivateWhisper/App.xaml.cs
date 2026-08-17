using System.Windows;

namespace PrivateWhisper;

/// <summary>
/// Tray-only WPF application (no main window): wires config, tray, overlay,
/// keyboard hook, pipeline, correction learner, and the sidecar lifecycles.
/// </summary>
public partial class App : Application
{
    private Mutex? singleInstanceMutex;
    private bool ownsMutex;

    private ConfigStore configStore = null!;
    private TrayController tray = null!;
    private OverlayWindow overlay = null!;
    private HotkeyHook hook = null!;
    private PipelineController pipeline = null!;
    private CorrectionLearner learner = null!;
    private WhisperSidecar whisperSidecar = null!;
    private LlamaSidecar llamaSidecar = null!;

    private SettingsWindow? settingsWindow;
    private StatsWindow? statsWindow;
    private DictionaryWindow? dictionaryWindow;
    private FirstRunWindow? firstRunWindow;

    public OverlayWindow Overlay => overlay;
    public ConfigStore Config => configStore;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        singleInstanceMutex = new Mutex(true, "PrivateWhisper.SingleInstance", out bool createdNew);
        ownsMutex = createdNew;
        if (!createdNew)
        {
            MessageBox.Show(
                "Private Whisper is already running — look for its icon in the system tray.",
                "Private Whisper");
            Shutdown();
            return;
        }

        // A tray app must not die from a stray exception in an event handler;
        // log it and keep running.
        DispatcherUnhandledException += (_, args) =>
        {
            Log.D("Unhandled dispatcher exception: " + args.Exception);
            args.Handled = true;
        };

        Log.D($"=== Private Whisper starting (portable={AppConfig.IsPortable}) ===");

        configStore = new ConfigStore();
        overlay = new OverlayWindow(configStore) { Enabled = configStore.Config.OverlayEnabled };
        tray = new TrayController();
        whisperSidecar = new WhisperSidecar(configStore);
        llamaSidecar = new LlamaSidecar();
        pipeline = new PipelineController(configStore, tray, overlay, whisperSidecar, llamaSidecar);

        learner = new CorrectionLearner(configStore);
        learner.OnSuggestions += terms =>
        {
            SuggestionStore.Add(terms);
            tray.ShowSuggestionBalloon(terms);
        };
        pipeline.CorrectionLearner = learner;

        hook = new HotkeyHook();
        hook.DictationPressed += pipeline.HotkeyPressed;
        hook.DictationReleased += pipeline.HotkeyReleased;
        hook.CommandPressed += pipeline.CommandPressed;
        hook.CommandReleased += pipeline.CommandReleased;
        hook.Start(CurrentDictationVk(), CurrentCommandVk());

        configStore.Changed += OnConfigChanged;

        tray.OpenSettings = ShowSettings;
        tray.OpenStats = ShowStats;
        tray.OpenDictionary = ShowDictionary;
        tray.OpenModels = ShowFirstRun;
        tray.QuitRequested = Shutdown;

        LaunchAtLogin.Apply(configStore.Config.LaunchAtLogin);

        if (!File.Exists(configStore.Config.WhisperModelPath))
        {
            ShowFirstRun();
        }
        else
        {
            pipeline.Preload();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            hook?.Dispose();
            pipeline?.Shutdown();
            tray?.Dispose();
        }
        catch (Exception ex)
        {
            Log.D("shutdown cleanup failed: " + ex.Message);
        }
        if (ownsMutex)
        {
            try { singleInstanceMutex?.ReleaseMutex(); } catch { }
        }
        singleInstanceMutex?.Dispose();
        Log.D("=== Private Whisper exiting ===");
        base.OnExit(e);
    }

    private uint CurrentDictationVk() => Hotkeys.VirtualKey(configStore.Config.Hotkey);

    private uint? CurrentCommandVk() =>
        configStore.Config.CommandHotkey == null
            ? null
            : Hotkeys.VirtualKey(configStore.Config.CommandHotkey);

    private void OnConfigChanged()
    {
        hook.UpdateKeys(CurrentDictationVk(), CurrentCommandVk());
        overlay.Enabled = configStore.Config.OverlayEnabled;
        LaunchAtLogin.Apply(configStore.Config.LaunchAtLogin);
    }

    // ---- Window management (one instance of each) ----

    private void ShowSettings()
    {
        settingsWindow = ShowOrActivate(settingsWindow, () => new SettingsWindow(configStore, overlay));
    }

    private void ShowStats()
    {
        statsWindow = ShowOrActivate(statsWindow, () => new StatsWindow());
    }

    private void ShowDictionary()
    {
        dictionaryWindow = ShowOrActivate(dictionaryWindow, () => new DictionaryWindow(configStore));
    }

    private void ShowFirstRun()
    {
        firstRunWindow = ShowOrActivate(firstRunWindow, () => new FirstRunWindow(configStore, pipeline));
    }

    private static T ShowOrActivate<T>(T? existing, Func<T> factory) where T : Window
    {
        if (existing is { IsLoaded: true })
        {
            existing.Activate();
            return existing;
        }
        T window = factory();
        window.Show();
        window.Activate();
        return window;
    }
}
