using System.Diagnostics;

namespace PrivateWhisper;

/// <summary>Identifies the foreground app for per-app tone hints. Windows
/// counterpart of the Mac bundle-ID lookup: appTones is keyed by the process
/// name, lowercase, with ".exe" (e.g. "outlook.exe").</summary>
public static class ForegroundApp
{
    public static string? ProcessNameLower()
    {
        try
        {
            IntPtr hwnd = NativeMethods.GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return null;
            NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0) return null;
            using Process process = Process.GetProcessById((int)pid);
            return process.ProcessName.ToLowerInvariant() + ".exe";
        }
        catch
        {
            return null;
        }
    }
}
