using ProgressBar = System.Windows.Controls.ProgressBar;
using Button = System.Windows.Controls.Button;
using System.Windows;
using System.Windows.Controls;

namespace PrivateWhisper;

/// <summary>
/// First-run / model management window: the two model download rows with
/// per-item progress bars, driven by ModelDownloader events.
/// </summary>
public partial class FirstRunWindow : Window
{
    private readonly ConfigStore configStore;
    private readonly PipelineController pipeline;
    private readonly string whisperKey;
    private const string CleanupKey = "cleanup-llm";

    public FirstRunWindow(ConfigStore configStore, PipelineController pipeline)
    {
        this.configStore = configStore;
        this.pipeline = pipeline;
        whisperKey = configStore.Config.WhisperModel;
        InitializeComponent();

        if (ModelManifest.Items.TryGetValue(whisperKey, out ModelManifest.Entry? whisperItem))
        {
            WhisperLabel.Text = whisperItem.Label;
            WhisperSizeLabel.Text = whisperItem.Size;
        }
        if (ModelManifest.Items.TryGetValue(CleanupKey, out ModelManifest.Entry? cleanupItem))
        {
            CleanupLabel.Text = cleanupItem.Label;
            CleanupSizeLabel.Text = cleanupItem.Size;
        }

        ModelDownloader.Shared.StateChanged += OnDownloadStateChanged;
        Closed += (_, _) => ModelDownloader.Shared.StateChanged -= OnDownloadStateChanged;

        RefreshRow(whisperKey);
        RefreshRow(CleanupKey);
    }

    private void OnDownloadStateChanged(string key, ModelDownloader.DownloadState state)
    {
        Dispatcher.BeginInvoke(() =>
        {
            RefreshRow(key);
            if (!state.Downloading && state.Error == null && key == whisperKey &&
                ModelDownloader.IsInstalled(whisperKey))
            {
                pipeline.Preload();
            }
        });
    }

    private void RefreshRow(string key)
    {
        (ProgressBar bar, TextBlock status, Button button) = key == CleanupKey
            ? (CleanupProgress, CleanupStatus, CleanupDownloadButton)
            : (WhisperProgress, WhisperStatus, WhisperDownloadButton);
        if (key != CleanupKey && key != whisperKey) return;

        ModelDownloader.DownloadState state = ModelDownloader.Shared.GetState(key);
        bool installed = ModelDownloader.IsInstalled(key);

        if (installed && !state.Downloading)
        {
            bar.Value = 1;
            status.Text = "Installed ✓";
            button.IsEnabled = false;
            button.Content = "Installed";
        }
        else if (state.Downloading)
        {
            bar.Value = state.Progress;
            status.Text = $"Downloading… {state.Progress:P0}";
            button.IsEnabled = false;
            button.Content = "Download";
        }
        else
        {
            bar.Value = 0;
            status.Text = state.Error != null ? "Failed: " + state.Error : "Not downloaded";
            button.IsEnabled = true;
            button.Content = state.Error != null ? "Retry" : "Download";
        }
    }

    private void WhisperDownloadButton_Click(object sender, RoutedEventArgs e)
    {
        ModelDownloader.Shared.Download(whisperKey);
    }

    private void CleanupDownloadButton_Click(object sender, RoutedEventArgs e)
    {
        ModelDownloader.Shared.Download(CleanupKey);
    }

    private void ContinueButton_Click(object sender, RoutedEventArgs e) => Close();
}
