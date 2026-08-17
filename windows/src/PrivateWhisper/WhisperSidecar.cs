using System.Globalization;

namespace PrivateWhisper;

/// <summary>
/// whisper.cpp's whisper-server.exe as a localhost sidecar (the Windows
/// equivalent of the Mac app's in-process whisper.cpp). Official ggml-org
/// release binary, expected under runtime\whisper\ (or runtime\ flat).
/// </summary>
public sealed class WhisperSidecar : SidecarServer
{
    private readonly ConfigStore configStore;

    public WhisperSidecar(ConfigStore configStore)
    {
        this.configStore = configStore;
    }

    protected override string Name => "whisper";
    protected override string BinaryFileName => "whisper-server.exe";
    protected override string SubdirectoryName => "whisper";
    protected override string BaseUrlSuffix => "";

    protected override string CurrentModelPath => configStore.Config.WhisperModelPath;

    protected override IEnumerable<string> BuildArguments(string modelPath, int serverPort)
    {
        int threads = Math.Max(4, Environment.ProcessorCount - 2);
        return new[]
        {
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", serverPort.ToString(CultureInfo.InvariantCulture),
            "-t", threads.ToString(CultureInfo.InvariantCulture),
        };
    }
}
