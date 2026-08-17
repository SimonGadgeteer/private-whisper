using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using NAudio.CoreAudioApi;

namespace PrivateWhisper;

/// <summary>Settings UI — functional over pretty, mirrors the Mac settings.</summary>
public partial class SettingsWindow : Window
{
    private sealed record ComboItem(string? Id, string Label)
    {
        public override string ToString() => Label;
    }

    private readonly ConfigStore configStore;
    private readonly OverlayWindow overlay;

    public SettingsWindow(ConfigStore configStore, OverlayWindow overlay)
    {
        this.configStore = configStore;
        this.overlay = overlay;
        InitializeComponent();
        LoadFromConfig();
    }

    private void LoadFromConfig()
    {
        AppConfig config = configStore.Config;

        HotkeyCombo.Items.Clear();
        foreach ((string id, string label) in Hotkeys.All)
        {
            HotkeyCombo.Items.Add(new ComboItem(id, label));
        }
        SelectById(HotkeyCombo, config.Hotkey);

        CommandHotkeyCombo.Items.Clear();
        CommandHotkeyCombo.Items.Add(new ComboItem(null, "Disabled"));
        foreach ((string id, string label) in Hotkeys.All)
        {
            CommandHotkeyCombo.Items.Add(new ComboItem(id, label));
        }
        SelectById(CommandHotkeyCombo, config.CommandHotkey);

        MicrophoneCombo.Items.Clear();
        MicrophoneCombo.Items.Add(new ComboItem(null, "System default"));
        try
        {
            var enumerator = new MMDeviceEnumerator();
            try
            {
                foreach (MMDevice device in enumerator.EnumerateAudioEndPoints(
                             DataFlow.Capture, DeviceState.Active))
                {
                    MicrophoneCombo.Items.Add(new ComboItem(device.ID, device.FriendlyName));
                    device.Dispose();
                }
            }
            finally
            {
                enumerator.Dispose();
            }
        }
        catch (Exception ex)
        {
            Log.D("mic enumeration failed: " + ex.Message);
        }
        SelectById(MicrophoneCombo, config.MicrophoneDeviceId);

        WhisperModelCombo.Items.Clear();
        foreach (string key in ModelManifest.Items.Keys.Where(k => k != "cleanup-llm").OrderBy(k => k))
        {
            string suffix = ModelDownloader.IsInstalled(key) ? "" : "  (not downloaded)";
            WhisperModelCombo.Items.Add(new ComboItem(key, key + suffix));
        }
        SelectById(WhisperModelCombo, config.WhisperModel);

        CleanupEnabledCheck.IsChecked = config.CleanupEnabled;
        LmStudioUrlBox.Text = config.LmStudioUrl;
        CleanupModelCombo.Text = config.CleanupModel;
        TimeoutBox.Text = config.CleanupTimeoutSeconds.ToString(CultureInfo.InvariantCulture);
        OverlayEnabledCheck.IsChecked = config.OverlayEnabled;
        LaunchAtLoginCheck.IsChecked = config.LaunchAtLogin;
        HistoryLoggingCheck.IsChecked = config.HistoryLoggingEnabled;
        CorrectionLearningCheck.IsChecked = config.CorrectionLearningEnabled;
    }

    private static void SelectById(ComboBox combo, string? id)
    {
        foreach (object item in combo.Items)
        {
            if (item is ComboItem comboItem && comboItem.Id == id)
            {
                combo.SelectedItem = item;
                return;
            }
        }
        if (combo.Items.Count > 0) combo.SelectedIndex = 0;
    }

    private async void RefreshModelsButton_Click(object sender, RoutedEventArgs e)
    {
        RefreshModelsButton.IsEnabled = false;
        try
        {
            string current = CleanupModelCombo.Text;
            IReadOnlyList<string> models = await CleanupService.AvailableModelsAsync(LmStudioUrlBox.Text.Trim());
            CleanupModelCombo.Items.Clear();
            foreach (string model in models)
            {
                CleanupModelCombo.Items.Add(model);
            }
            CleanupModelCombo.Text = current;
            if (models.Count == 0)
            {
                MessageBox.Show(this,
                    "No models reported. Is LM Studio running at " + LmStudioUrlBox.Text.Trim() + "?",
                    "Private Whisper");
            }
        }
        finally
        {
            RefreshModelsButton.IsEnabled = true;
        }
    }

    private void MoveOverlayButton_Click(object sender, RoutedEventArgs e)
    {
        overlay.EnterMovePreview();
    }

    private void ResetOverlayButton_Click(object sender, RoutedEventArgs e)
    {
        overlay.ResetPosition();
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        string hotkey = (HotkeyCombo.SelectedItem as ComboItem)?.Id ?? Hotkeys.RightAlt;
        string? commandHotkey = (CommandHotkeyCombo.SelectedItem as ComboItem)?.Id;
        if (commandHotkey != null && commandHotkey == hotkey)
        {
            MessageBox.Show(this,
                "Dictation and command mode must use different keys.",
                "Private Whisper");
            return;
        }
        if (!double.TryParse(TimeoutBox.Text.Trim(), NumberStyles.Float,
                CultureInfo.InvariantCulture, out double timeout) || timeout <= 0)
        {
            timeout = 15;
        }

        string? microphoneId = (MicrophoneCombo.SelectedItem as ComboItem)?.Id;
        string whisperModel = (WhisperModelCombo.SelectedItem as ComboItem)?.Id ?? "large-v3-turbo";
        string lmStudioUrl = LmStudioUrlBox.Text.Trim();
        string cleanupModel = CleanupModelCombo.Text.Trim();

        configStore.Update(c =>
        {
            c.Hotkey = hotkey;
            c.CommandHotkey = commandHotkey;
            c.MicrophoneDeviceId = microphoneId;
            c.WhisperModel = whisperModel;
            c.CleanupEnabled = CleanupEnabledCheck.IsChecked == true;
            if (lmStudioUrl.Length > 0) c.LmStudioUrl = lmStudioUrl;
            if (cleanupModel.Length > 0) c.CleanupModel = cleanupModel;
            c.CleanupTimeoutSeconds = timeout;
            c.OverlayEnabled = OverlayEnabledCheck.IsChecked == true;
            c.LaunchAtLogin = LaunchAtLoginCheck.IsChecked == true;
            c.HistoryLoggingEnabled = HistoryLoggingCheck.IsChecked == true;
            c.CorrectionLearningEnabled = CorrectionLearningCheck.IsChecked == true;
        });
        Close();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        overlay.ExitMovePreview(persistPosition: false);
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        // If the window is closed while the overlay is still in move-preview,
        // leave things consistent (no persist).
        overlay.ExitMovePreview(persistPosition: false);
        base.OnClosed(e);
    }
}
