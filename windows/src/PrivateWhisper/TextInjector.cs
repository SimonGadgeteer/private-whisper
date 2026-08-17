using DataFormats = System.Windows.DataFormats;
using DataObject = System.Windows.DataObject;
using IDataObject = System.Windows.IDataObject;
using Clipboard = System.Windows.Clipboard;
using System.Runtime.InteropServices;
using System.Windows;

namespace PrivateWhisper;

public enum InjectionKind
{
    Injected,
    /// <summary>Text was not injected; the caller should surface it instead.</summary>
    NeedsOverlay,
}

public readonly struct InjectionOutcome
{
    public InjectionKind Kind { get; }
    public string? Reason { get; }

    private InjectionOutcome(InjectionKind kind, string? reason)
    {
        Kind = kind;
        Reason = reason;
    }

    public static InjectionOutcome Injected() => new(InjectionKind.Injected, null);
    public static InjectionOutcome NeedsOverlay(string reason) => new(InjectionKind.NeedsOverlay, reason);
}

/// <summary>
/// Injects text at the cursor of the foreground app: clipboard + synthetic
/// Ctrl+V, then restores the previous clipboard contents (PRD §4.1-D).
/// The restore is guarded by GetClipboardSequenceNumber — if anyone (the user
/// copying, a newer dictation) wrote to the clipboard in the meantime, the
/// restore is skipped so newer content is never clobbered. Windows analog of
/// the Mac changeCount guard. Must be called on the UI (STA) thread.
/// </summary>
public static class TextInjector
{
    /// <summary>Monotonic generation so only the latest scheduled restore runs
    /// when dictations overlap within the restore window.</summary>
    private static int restoreGeneration;

    public static InjectionOutcome Inject(string text)
    {
        DataObject? snapshot = SnapshotClipboard();

        if (!TrySetClipboardText(text))
        {
            return InjectionOutcome.NeedsOverlay("Clipboard is busy (another app holds it open)");
        }
        uint expectedSequence = NativeMethods.GetClipboardSequenceNumber();
        int generation = ++restoreGeneration;

        SyntheticKeyboard.SendCtrlV();

        // Give the target app time to read the clipboard before restoring.
        _ = RestoreLaterAsync(snapshot, expectedSequence, generation);
        return InjectionOutcome.Injected();
    }

    private static async Task RestoreLaterAsync(DataObject? snapshot, uint expectedSequence, int generation)
    {
        await Task.Delay(600); // resumes on the UI thread (dispatcher context)
        if (generation != restoreGeneration) return;
        if (NativeMethods.GetClipboardSequenceNumber() != expectedSequence) return;
        try
        {
            if (snapshot == null)
            {
                Clipboard.Clear();
            }
            else
            {
                Clipboard.SetDataObject(snapshot, true);
            }
        }
        catch (Exception ex)
        {
            Log.D("clipboard restore failed: " + ex.Message);
        }
    }

    /// <summary>Snapshot every readable format so rich content survives the
    /// round-trip. Individual formats that refuse to serialize are skipped.</summary>
    internal static DataObject? SnapshotClipboard()
    {
        try
        {
            IDataObject? source = Clipboard.GetDataObject();
            if (source == null) return null;
            var copy = new DataObject();
            bool any = false;
            foreach (string format in source.GetFormats(false))
            {
                try
                {
                    if (source.GetDataPresent(format, false))
                    {
                        object? data = source.GetData(format, false);
                        if (data != null)
                        {
                            copy.SetData(format, data);
                            any = true;
                        }
                    }
                }
                catch
                {
                    // Some formats throw on read (delayed rendering, dead owner) — skip.
                }
            }
            return any ? copy : null;
        }
        catch (Exception ex)
        {
            Log.D("clipboard snapshot failed: " + ex.Message);
            return null;
        }
    }

    internal static bool TrySetClipboardText(string text)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true);
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(40); // clipboard briefly locked by another app
            }
            catch (Exception ex)
            {
                Log.D("clipboard set failed: " + ex.Message);
                return false;
            }
        }
        return false;
    }
}
