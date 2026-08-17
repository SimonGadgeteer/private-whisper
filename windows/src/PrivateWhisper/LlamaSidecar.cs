using System.Globalization;

namespace PrivateWhisper;

/// <summary>
/// llama.cpp's llama-server.exe as the embedded cleanup backend (port of the
/// Mac EmbeddedLLMServer). Args mirror shared/model_manifest.json — notably
/// the enable_thinking=false chat-template kwarg (llama-server's
/// --reasoning-budget 0 does NOT stop Qwen 3.5 thinking; this kwarg does).
/// </summary>
public sealed class LlamaSidecar : SidecarServer
{
    public const string ModelFileName = "Qwen3.5-4B-Q4_K_M.gguf";

    public static string ModelFilePath => Path.Combine(AppConfig.ModelsDir, ModelFileName);

    public static bool IsModelInstalled => File.Exists(ModelFilePath);

    protected override string Name => "embedded-llm";
    protected override string BinaryFileName => "llama-server.exe";
    protected override string SubdirectoryName => "llama";
    protected override string BaseUrlSuffix => "/v1";

    protected override string CurrentModelPath => ModelFilePath;

    protected override IEnumerable<string> BuildArguments(string modelPath, int serverPort)
    {
        return new[]
        {
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", serverPort.ToString(CultureInfo.InvariantCulture),
            "-c", "8192",
            "-ngl", "99",
            "--chat-template-kwargs", "{\"enable_thinking\": false}",
            "--no-webui",
        };
    }
}
