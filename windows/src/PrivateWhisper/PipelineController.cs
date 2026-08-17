using System.Diagnostics;

namespace PrivateWhisper;

public enum PipelineState
{
    Idle,
    Recording,
    Processing,
    Injected,
    Warning,
}

/// <summary>
/// Orchestrates key press → record → transcribe → cleanup → inject, plus
/// command mode (voice-edit the current selection). Port of the Mac
/// PipelineController; runs on the WPF UI thread (the @MainActor analog).
///
/// Re-trigger policy (PRD §7.7): a new dictation started while the previous
/// one is still processing is REJECTED with a brief flash. Queuing would risk
/// injecting stale text into whatever app gained focus later.
/// </summary>
public sealed class PipelineController
{
    private readonly ConfigStore configStore;
    private readonly TrayController tray;
    private readonly OverlayWindow overlay;
    private readonly AudioRecorder recorder = new();
    private readonly WhisperSidecar whisperSidecar;
    private readonly LlamaSidecar llamaSidecar;
    private readonly WhisperServerTranscriber transcriber;

    /// <summary>Set by App; watches injected fields for manual corrections.</summary>
    public CorrectionLearner? CorrectionLearner { get; set; }

    private enum SessionMode { Dictation, Command }

    private SessionMode sessionMode = SessionMode.Dictation;
    private string? sessionToneHint;
    private string sessionSelection = "";

    public PipelineController(
        ConfigStore configStore, TrayController tray, OverlayWindow overlay,
        WhisperSidecar whisperSidecar, LlamaSidecar llamaSidecar)
    {
        this.configStore = configStore;
        this.tray = tray;
        this.overlay = overlay;
        this.whisperSidecar = whisperSidecar;
        this.llamaSidecar = llamaSidecar;
        transcriber = new WhisperServerTranscriber(whisperSidecar);

        recorder.LevelChanged += level =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(
                () => overlay.UpdateLevel(level));
        };
    }

    /// <summary>Warms the whisper sidecar so the first dictation is fast.
    /// Quiet no-op when the model isn't downloaded yet (setup flow handles it).</summary>
    public void Preload()
    {
        if (!File.Exists(configStore.Config.WhisperModelPath))
        {
            Log.D("preload skipped: whisper model not downloaded yet");
            return;
        }
        _ = whisperSidecar.EnsureRunningAsync();
    }

    /// <summary>Only Recording and Processing block a new session; transient
    /// states (Injected, Warning) must never lock out the hotkey.</summary>
    private bool CanStartSession()
    {
        switch (tray.State)
        {
            case PipelineState.Recording:
                return false;
            case PipelineState.Processing:
                overlay.Flash("Still processing…", 1.5);
                return false;
            default:
                return true;
        }
    }

    private void StartRecording()
    {
        try
        {
            recorder.Start(configStore.Config.MicrophoneDeviceId);
            tray.SetState(PipelineState.Recording);
            overlay.ShowRecording();
            Log.D("Recording started");
        }
        catch (Exception ex)
        {
            tray.SetState(PipelineState.Warning, "Microphone unavailable");
            overlay.Flash("Could not start recording: " + ex.Message, 3);
        }
    }

    // ---- Dictation ----

    public void HotkeyPressed()
    {
        if (!CanStartSession()) return;
        // Capture the target app now — focus can change during processing.
        string? app = ForegroundApp.ProcessNameLower();
        sessionToneHint = app != null && configStore.Config.AppTones.TryGetValue(app, out string? tone)
            ? tone
            : null;
        sessionMode = SessionMode.Dictation;
        StartRecording();
    }

    public void HotkeyReleased() => FinishRecording();

    // ---- Command mode ----

    public async void CommandPressed()
    {
        try
        {
            if (configStore.Config.CommandHotkey == null || !CanStartSession()) return;
            string? selection = await SelectionCapture.GetSelectedTextAsync();
            if (string.IsNullOrEmpty(selection))
            {
                overlay.Flash("Command mode: select some text first", 2);
                return;
            }
            // Re-check: the async selection capture takes ~100ms and the user
            // may have released the key already — the hook still fires
            // onRelease, which no-ops if we never started recording.
            if (!CanStartSession()) return;
            sessionMode = SessionMode.Command;
            sessionSelection = selection;
            StartRecording();
        }
        catch (Exception ex)
        {
            Log.D("command press failed: " + ex.Message);
        }
    }

    public void CommandReleased() => FinishRecording();

    // ---- Shared pipeline ----

    private async void FinishRecording()
    {
        try
        {
            // Keyed off the recorder, not the UI state: even if something
            // clobbered the Recording state, the mic must never be left running.
            if (!recorder.IsRecording) return;
            float[] samples = recorder.Stop();
            double audioSeconds = samples.Length / 16000.0;
            Log.D($"Recording stopped: {audioSeconds:F2}s audio, rms={AudioGate.Rms(samples):F4}");

            // PRD §7.4: discard empty/near-silent recordings.
            if (!AudioGate.Passes(samples))
            {
                tray.SetState(PipelineState.Idle);
                overlay.Flash("Nothing heard", 1.5);
                return;
            }

            tray.SetState(PipelineState.Processing);
            overlay.ShowProcessing("Transcribing…");
            AppConfig config = configStore.Config;
            SessionMode mode = sessionMode;
            string? toneHint = sessionToneHint;
            string selection = sessionSelection;

            var stopwatch = Stopwatch.StartNew();
            TranscriptionResult result = await transcriber.TranscribeAsync(samples, config.Dictionary);
            double transcriptionSeconds = stopwatch.Elapsed.TotalSeconds;

            if (string.IsNullOrEmpty(result.Text))
            {
                tray.SetState(PipelineState.Idle);
                overlay.Flash("Nothing heard", 1.5);
                return;
            }

            if (mode == SessionMode.Dictation)
            {
                await FinishDictationAsync(result, config, toneHint, audioSeconds, transcriptionSeconds);
            }
            else
            {
                await FinishCommandAsync(result.Text, selection, config);
            }
        }
        catch (Exception ex)
        {
            tray.SetState(PipelineState.Warning, "Transcription failed");
            overlay.Flash("Transcription failed: " + ex.Message, 4);
        }
    }

    private async Task FinishDictationAsync(
        TranscriptionResult result, AppConfig config, string? toneHint,
        double audioSeconds, double transcriptionSeconds)
    {
        string finalText = result.Text;
        double? cleanupSeconds = null;
        bool fellBack = false;

        if (config.CleanupEnabled)
        {
            (string BaseUrl, string Model)? backend =
                await CleanupService.ResolveBackendAsync(config, llamaSidecar);
            if (backend == null)
            {
                // PRD §4.1-C: never lose the dictation — fall back to raw.
                fellBack = true;
                Log.D("No cleanup backend reachable — using raw transcript");
            }
            else
            {
                var cleanup = new CleanupService(
                    backend.Value.BaseUrl, backend.Value.Model, config.CleanupTimeoutSeconds);
                var stopwatch = Stopwatch.StartNew();
                try
                {
                    finalText = await cleanup.CleanupAsync(
                        result.Text, result.Language, config.Dictionary, toneHint);
                    cleanupSeconds = stopwatch.Elapsed.TotalSeconds;
                }
                catch (Exception ex)
                {
                    fellBack = true;
                    Log.D("Cleanup failed, using raw transcript: " + ex.Message);
                }
            }
        }

        finalText = CorrectionLearner.EnforceDictionary(finalText, config.Dictionary);
        InjectionKind delivery = Deliver(finalText, fellBack);
        if (delivery == InjectionKind.Injected)
        {
            CorrectionLearner?.Watch(finalText);
        }

        StatsStore.Shared.Record(
            words: finalText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length,
            language: result.Language,
            audioSeconds: audioSeconds,
            transcriptionSeconds: transcriptionSeconds,
            cleanupSeconds: cleanupSeconds,
            fellBack: fellBack);

        if (config.HistoryLoggingEnabled)
        {
            HistoryLogger.Append(new HistoryLogger.Entry(
                Timestamp: DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
                Language: result.Language,
                RawTranscript: result.Text,
                CleanedText: fellBack || !config.CleanupEnabled ? null : finalText,
                AudioSeconds: audioSeconds,
                TranscriptionSeconds: transcriptionSeconds,
                CleanupSeconds: cleanupSeconds));
        }
    }

    private async Task FinishCommandAsync(string instruction, string selection, AppConfig config)
    {
        // Command mode has no raw fallback that makes sense — the LLM *is* the
        // feature. Longer timeout: rewrites scale with selection length.
        (string BaseUrl, string Model)? backend =
            await CleanupService.ResolveBackendAsync(config, llamaSidecar);
        if (backend == null)
        {
            tray.SetState(PipelineState.Warning, "No cleanup model available");
            overlay.Flash("Command mode needs LM Studio or the embedded cleanup model", 4);
            return;
        }
        var cleanup = new CleanupService(
            backend.Value.BaseUrl, backend.Value.Model,
            Math.Max(30, config.CleanupTimeoutSeconds * 2));
        try
        {
            string prefix = instruction.Length <= 60 ? instruction : instruction[..60];
            Log.D($"Command mode: \"{prefix}\" on {selection.Length} chars");
            string rewritten = await cleanup.RewriteAsync(selection, instruction);
            Deliver(rewritten, fellBack: false);
        }
        catch (Exception ex)
        {
            tray.SetState(PipelineState.Warning, "Command mode failed");
            overlay.Flash("Command mode failed: " + ex.Message, 4);
        }
    }

    /// <summary>Kills the sidecars and the mic on app exit.</summary>
    public void Shutdown()
    {
        if (recorder.IsRecording)
        {
            recorder.Stop();
        }
        whisperSidecar.Stop();
        llamaSidecar.Stop();
    }

    private InjectionKind Deliver(string text, bool fellBack)
    {
        tray.LastDictation = text;
        InjectionOutcome outcome = TextInjector.Inject(text);
        if (outcome.Kind == InjectionKind.Injected)
        {
            Log.D($"Injected {text.Length} chars");
            if (fellBack)
            {
                tray.SetState(PipelineState.Warning, "Inserted raw transcript (cleanup offline)");
                overlay.Flash("Inserted raw transcript (cleanup offline)", 2.5);
            }
            else
            {
                tray.SetState(PipelineState.Injected);
                overlay.FlashSuccess();
            }
        }
        else
        {
            Log.D("Injection fell back to overlay: " + outcome.Reason);
            tray.SetState(
                fellBack ? PipelineState.Warning : PipelineState.Idle,
                fellBack ? "Cleanup offline — raw transcript shown" : null);
            overlay.ShowText(outcome.Reason ?? "Could not insert text");
        }
        return outcome.Kind;
    }
}
