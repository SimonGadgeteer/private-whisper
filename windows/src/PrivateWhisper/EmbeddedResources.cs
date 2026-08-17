using System.Reflection;
using System.Text;

namespace PrivateWhisper;

/// <summary>
/// Reads assets embedded from the repo's shared/ directory (prompts, model
/// manifest). These are the single source of truth across platforms — the
/// prompt text is eval-verified and must not be re-typed per platform.
/// </summary>
public static class EmbeddedResources
{
    public static string ReadText(string name)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using Stream stream = asm.GetManifestResourceStream("PrivateWhisper.Resources." + name)
            ?? throw new InvalidOperationException("Missing embedded resource: " + name);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd().Trim();
    }
}
