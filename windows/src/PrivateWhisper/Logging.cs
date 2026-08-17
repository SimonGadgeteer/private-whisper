namespace PrivateWhisper;

/// <summary>
/// Minimal append-only debug log (equivalent of the Mac app's dlog/app.log).
/// Never throws: logging must not be able to break the pipeline.
/// </summary>
public static class Log
{
    private static readonly object Sync = new();

    public static void D(string message)
    {
        string line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}";
        System.Diagnostics.Debug.WriteLine(line);
        try
        {
            lock (Sync)
            {
                Directory.CreateDirectory(AppConfig.SupportDir);
                File.AppendAllText(AppConfig.LogPath, line + Environment.NewLine);
            }
        }
        catch
        {
            // Best-effort only.
        }
    }
}
