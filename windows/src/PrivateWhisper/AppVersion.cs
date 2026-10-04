using System.Reflection;

namespace PrivateWhisper;

/// <summary>The running build's identity, for Settings, the tray menu and the log. The version and
/// commit come from package.ps1 (-p:Version, -p:SourceRevisionId), giving an informational version
/// like "0.2.5+87f0f59".</summary>
public static class AppVersion
{
    private static readonly string Informational =
        Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "dev";

    /// <summary>"0.2.5"</summary>
    public static string Version => Informational.Split('+')[0];

    /// <summary>"87f0f59", or null for local builds without a commit.</summary>
    public static string? Commit
    {
        get
        {
            int plus = Informational.IndexOf('+');
            if (plus < 0) return null;
            string sha = Informational[(plus + 1)..];
            return sha.Length > 7 ? sha[..7] : sha;
        }
    }

    /// <summary>"0.2.5 (commit 87f0f59)"</summary>
    public static string Full => Commit != null ? $"{Version} (commit {Commit})" : Version;
}
