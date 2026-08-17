using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace PrivateWhisper;

/// <summary>
/// Shared gate for discarding empty/near-silent recordings (PRD §7.4).
/// Whisper hallucinates ("you", "Thank you.") on silence — energy gating is
/// the real defense. Constants identical to the Mac AudioGate.
/// </summary>
public static class AudioGate
{
    public const double MinSeconds = 0.5;
    public const float MinRms = 0.002f;

    public static bool Passes(float[] samples) =>
        samples.Length / 16000.0 >= MinSeconds && Rms(samples) > MinRms;

    public static float Rms(float[] samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (float s in samples) sum += (double)s * s;
        return (float)Math.Sqrt(sum / samples.Length);
    }
}

/// <summary>
/// Captures microphone audio via WASAPI (NAudio) and accumulates a 16 kHz
/// mono Float32 buffer — whisper's expected input format. The device's mix
/// format (typically 44.1/48 kHz float, 1-2 channels) is downmixed and
/// linearly resampled in a streaming fashion.
/// </summary>
public sealed class AudioRecorder
{
    private readonly object sync = new();
    private readonly List<float> samples = new();

    private WasapiCapture? capture;
    private int session;
    private bool recording;

    // Streaming resampler state (guarded by sync).
    private double resamplePos;
    private float lastSourceSample;
    private bool hasLastSourceSample;

    /// <summary>Live per-chunk RMS for the overlay level meter. Raised on the
    /// audio callback thread — marshal to the UI thread before touching WPF.</summary>
    public event Action<float>? LevelChanged;

    public bool IsRecording
    {
        get { lock (sync) return recording; }
    }

    /// <summary>Starts capture. deviceId is an MMDevice ID; null = default device.</summary>
    public void Start(string? deviceId)
    {
        if (IsRecording) Stop(); // never stack sessions / leave a hot mic

        MMDevice? device = null;
        var enumerator = new MMDeviceEnumerator();
        try
        {
            if (!string.IsNullOrEmpty(deviceId))
            {
                try { device = enumerator.GetDevice(deviceId); }
                catch { device = null; } // unplugged since it was chosen → default
            }
            device ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        finally
        {
            enumerator.Dispose();
        }

        var cap = new WasapiCapture(device);
        WaveFormat format = cap.WaveFormat;
        if (format.SampleRate <= 0 || format.Channels <= 0)
        {
            cap.Dispose();
            throw new InvalidOperationException("No usable input device (invalid capture format).");
        }

        int currentSession;
        lock (sync)
        {
            samples.Clear();
            session++;
            currentSession = session;
            resamplePos = 0;
            hasLastSourceSample = false;
            lastSourceSample = 0;
        }

        cap.DataAvailable += (_, e) => OnDataAvailable(e, format, currentSession);
        cap.RecordingStopped += (_, _) => { /* disposal handled in Stop() */ };
        cap.StartRecording();

        lock (sync)
        {
            capture = cap;
            recording = true;
        }
    }

    /// <summary>Stops capture and returns the accumulated 16 kHz mono samples.</summary>
    public float[] Stop()
    {
        WasapiCapture? cap;
        lock (sync)
        {
            recording = false;
            cap = capture;
            capture = null;
        }
        if (cap != null)
        {
            try { cap.StopRecording(); } catch { }
            try { cap.Dispose(); } catch { }
        }
        lock (sync)
        {
            return samples.ToArray();
        }
    }

    private void OnDataAvailable(WaveInEventArgs e, WaveFormat format, int sessionAtStart)
    {
        float[] mono = ExtractMonoFrames(e.Buffer, e.BytesRecorded, format);
        if (mono.Length == 0) return;

        int emitted = 0;
        float chunkRms = 0;
        lock (sync)
        {
            if (sessionAtStart != session || !recording) return; // late callback from a dead session
            int before = samples.Count;
            ResampleAppend(mono, format.SampleRate);
            emitted = samples.Count - before;
            if (emitted > 0)
            {
                double sum = 0;
                for (int i = samples.Count - emitted; i < samples.Count; i++)
                {
                    sum += (double)samples[i] * samples[i];
                }
                chunkRms = (float)Math.Sqrt(sum / emitted);
            }
        }

        if (emitted > 0)
        {
            LevelChanged?.Invoke(chunkRms);
        }
    }

    /// <summary>Converts an interleaved capture buffer to mono float frames.
    /// WASAPI shared-mode buffers are 32-bit float in practice (the mix
    /// format); 16/24/32-bit PCM is handled for exclusive-mode edge cases.</summary>
    private static float[] ExtractMonoFrames(byte[] buffer, int bytes, WaveFormat format)
    {
        int channels = format.Channels;
        int bytesPerSample = format.BitsPerSample / 8;
        if (bytesPerSample <= 0 || channels <= 0) return Array.Empty<float>();
        int frames = bytes / (bytesPerSample * channels);
        if (frames <= 0) return Array.Empty<float>();

        bool isFloat =
            format.Encoding == WaveFormatEncoding.IeeeFloat ||
            (format.Encoding == WaveFormatEncoding.Extensible && format.BitsPerSample == 32);

        var mono = new float[frames];
        for (int f = 0; f < frames; f++)
        {
            float sum = 0;
            for (int c = 0; c < channels; c++)
            {
                int offset = (f * channels + c) * bytesPerSample;
                float v;
                if (isFloat && bytesPerSample == 4)
                {
                    v = BitConverter.ToSingle(buffer, offset);
                }
                else if (bytesPerSample == 2)
                {
                    v = BitConverter.ToInt16(buffer, offset) / 32768f;
                }
                else if (bytesPerSample == 4)
                {
                    v = BitConverter.ToInt32(buffer, offset) / 2147483648f;
                }
                else if (bytesPerSample == 3)
                {
                    int s = buffer[offset] | (buffer[offset + 1] << 8) | ((sbyte)buffer[offset + 2] << 16);
                    v = s / 8388608f;
                }
                else
                {
                    v = 0;
                }
                sum += v;
            }
            mono[f] = sum / channels;
        }
        return mono;
    }

    /// <summary>Streaming linear resampler: carries the last source sample and
    /// the fractional read position across chunks so there are no seams.
    /// Must be called under lock.</summary>
    private void ResampleAppend(float[] mono, int sourceRate)
    {
        if (sourceRate == 16000 && !hasLastSourceSample && resamplePos == 0)
        {
            // Fast path only valid before any resampler state exists.
            samples.AddRange(mono);
            lastSourceSample = mono[mono.Length - 1];
            hasLastSourceSample = true;
            resamplePos = 1.0; // next output aligns with the next source sample
            return;
        }

        double ratio = sourceRate / 16000.0;

        // Extended source: [lastSourceSample, mono...] so interpolation can
        // cross the chunk boundary.
        int extCount = hasLastSourceSample ? mono.Length + 1 : mono.Length;
        if (extCount < 2)
        {
            if (mono.Length > 0)
            {
                lastSourceSample = mono[mono.Length - 1];
                hasLastSourceSample = true;
            }
            return;
        }

        float SourceAt(int i)
        {
            if (hasLastSourceSample)
            {
                return i == 0 ? lastSourceSample : mono[i - 1];
            }
            return mono[i];
        }

        double pos = resamplePos;
        while (true)
        {
            int idx = (int)pos;
            if (idx + 1 > extCount - 1) break;
            double frac = pos - idx;
            float a = SourceAt(idx);
            float b = SourceAt(idx + 1);
            samples.Add((float)(a + (b - a) * frac));
            pos += ratio;
        }

        resamplePos = pos - (extCount - 1);
        lastSourceSample = mono[mono.Length - 1];
        hasLastSourceSample = true;
    }
}
