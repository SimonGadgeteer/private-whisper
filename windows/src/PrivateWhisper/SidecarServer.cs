using System.Diagnostics;
using System.Net;

namespace PrivateWhisper;

/// <summary>
/// Shared lifecycle for the two localhost sidecar servers (whisper-server,
/// llama-server), ported from the Mac EmbeddedLLMServer semantics:
/// random port 49152-65499, poll GET /health until 200, stop after 10 minutes
/// idle (frees RAM), kill on app exit.
///
/// Binaries are looked up under the app dir: runtime\&lt;name&gt;\&lt;binary&gt;
/// first (whisper.cpp and llama.cpp release zips ship *different* ggml*.dll
/// versions, so each server needs its own directory), then runtime\&lt;binary&gt;
/// as a flat fallback.
/// </summary>
public abstract class SidecarServer
{
    private static readonly HttpClient Http = new() { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly object stateLock = new();

    private Process? process;
    private int port;
    private string? startedModelPath;
    private CancellationTokenSource? idleCts;

    /// <summary>Idle window before the sidecar is stopped to reclaim memory.</summary>
    protected virtual double IdleSeconds => 600;

    /// <summary>Health-poll attempts at 250 ms each. Generous: model load on a
    /// CPU-only notebook can take minutes for the larger models.</summary>
    protected virtual int StartupPollAttempts => 480;

    protected abstract string Name { get; }
    protected abstract string BinaryFileName { get; }
    protected abstract string SubdirectoryName { get; }
    /// <summary>"" for whisper-server, "/v1" for llama-server.</summary>
    protected abstract string BaseUrlSuffix { get; }
    protected abstract string CurrentModelPath { get; }
    protected abstract IEnumerable<string> BuildArguments(string modelPath, int serverPort);

    public string? BaseUrl
    {
        get
        {
            lock (stateLock)
            {
                return process is { HasExited: false }
                    ? $"http://127.0.0.1:{port}{BaseUrlSuffix}"
                    : null;
            }
        }
    }

    /// <summary>Resolved sidecar binary path, or null when not installed.</summary>
    public string? BinaryPath
    {
        get
        {
            string nested = Path.Combine(AppConfig.BaseDir, "runtime", SubdirectoryName, BinaryFileName);
            if (File.Exists(nested)) return nested;
            string flat = Path.Combine(AppConfig.BaseDir, "runtime", BinaryFileName);
            return File.Exists(flat) ? flat : null;
        }
    }

    /// <summary>Starts the sidecar if needed and returns its base URL once
    /// healthy, or null when the binary/model is missing or startup failed.</summary>
    public async Task<string?> EnsureRunningAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return await EnsureRunningCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<string?> EnsureRunningCoreAsync()
    {
        string modelPath = CurrentModelPath;
        if (!File.Exists(modelPath))
        {
            return null;
        }

        TouchIdleTimer();

        bool runningWithSameModel;
        lock (stateLock)
        {
            runningWithSameModel = process is { HasExited: false } && modelPath == startedModelPath;
        }
        if (runningWithSameModel && await IsHealthyAsync().ConfigureAwait(false))
        {
            return BaseUrl;
        }

        Stop();

        string? binary = BinaryPath;
        if (binary == null)
        {
            Log.D($"{Name}: sidecar binary not found under {Path.Combine(AppConfig.BaseDir, "runtime")}");
            return null;
        }

        int newPort = Random.Shared.Next(49152, 65500);
        var psi = new ProcessStartInfo
        {
            FileName = binary,
            WorkingDirectory = Path.GetDirectoryName(binary)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            // Streams must be drained or the child blocks once the pipe fills.
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string arg in BuildArguments(modelPath, newPort))
        {
            psi.ArgumentList.Add(arg);
        }

        Process proc;
        try
        {
            proc = Process.Start(psi) ?? throw new InvalidOperationException("Process.Start returned null");
        }
        catch (Exception ex)
        {
            Log.D($"{Name}: failed to launch: {ex.Message}");
            return null;
        }
        proc.OutputDataReceived += (_, _) => { };
        proc.ErrorDataReceived += (_, _) => { };
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        lock (stateLock)
        {
            process = proc;
            port = newPort;
            startedModelPath = modelPath;
        }
        Log.D($"{Name}: starting on port {newPort}");

        for (int i = 0; i < StartupPollAttempts; i++)
        {
            await Task.Delay(250).ConfigureAwait(false);
            if (await IsHealthyAsync().ConfigureAwait(false))
            {
                TouchIdleTimer();
                Log.D($"{Name}: healthy");
                return BaseUrl;
            }
            if (proc.HasExited)
            {
                Log.D($"{Name}: exited during startup (code {proc.ExitCode})");
                lock (stateLock)
                {
                    process = null;
                }
                return null;
            }
        }
        Log.D($"{Name}: health check timed out");
        Stop();
        return null;
    }

    public void Stop()
    {
        Process? proc;
        lock (stateLock)
        {
            idleCts?.Cancel();
            idleCts = null;
            proc = process;
            process = null;
            startedModelPath = null;
        }
        if (proc == null) return;
        try
        {
            if (!proc.HasExited)
            {
                proc.Kill(entireProcessTree: true);
                Log.D($"{Name}: stopped");
            }
        }
        catch (Exception ex)
        {
            Log.D($"{Name}: stop failed: {ex.Message}");
        }
        finally
        {
            proc.Dispose();
        }
    }

    private async Task<bool> IsHealthyAsync()
    {
        int currentPort;
        lock (stateLock)
        {
            if (process is not { HasExited: false }) return false;
            currentPort = port;
        }
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            using HttpResponseMessage response = await Http
                .GetAsync($"http://127.0.0.1:{currentPort}/health", cts.Token)
                .ConfigureAwait(false);
            return response.StatusCode == HttpStatusCode.OK;
        }
        catch
        {
            return false;
        }
    }

    private void TouchIdleTimer()
    {
        CancellationToken token;
        lock (stateLock)
        {
            idleCts?.Cancel();
            idleCts = new CancellationTokenSource();
            token = idleCts.Token;
        }
        double idleSeconds = IdleSeconds;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(idleSeconds), token).ConfigureAwait(false);
            }
            catch (TaskCanceledException)
            {
                return;
            }
            if (!token.IsCancellationRequested)
            {
                Log.D($"{Name}: idle — stopping to free memory");
                Stop();
            }
        });
    }
}
