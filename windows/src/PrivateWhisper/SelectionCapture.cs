using DataObject = System.Windows.DataObject;
using Clipboard = System.Windows.Clipboard;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PrivateWhisper;

/// <summary>
/// Reads the current selection in the foreground app for command mode.
/// First choice: UI Automation TextPattern (no side effects). Fallback:
/// synthetic Ctrl+C with clipboard snapshot/restore — works in apps that
/// don't expose UIA text (some Electron builds), at the cost of briefly
/// touching the clipboard. Call on the UI thread.
/// </summary>
public static class SelectionCapture
{
    public static async Task<string?> GetSelectedTextAsync()
    {
        string? viaUia = await Task.Run(GetSelectionViaUia);
        if (!string.IsNullOrWhiteSpace(viaUia))
        {
            return viaUia;
        }
        return await GetSelectionViaClipboardAsync();
    }

    private static string? GetSelectionViaUia()
    {
        try
        {
            AutomationElement? focused = AutomationElement.FocusedElement;
            if (focused == null) return null;
            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out object patternObj) &&
                patternObj is TextPattern textPattern)
            {
                TextPatternRange[] ranges = textPattern.GetSelection();
                if (ranges.Length == 0) return null;
                var parts = new List<string>();
                foreach (TextPatternRange range in ranges)
                {
                    parts.Add(range.GetText(-1));
                }
                string text = string.Concat(parts);
                return string.IsNullOrWhiteSpace(text) ? null : text;
            }
        }
        catch (Exception ex)
        {
            Log.D("selection via UIA failed: " + ex.Message);
        }
        return null;
    }

    private static async Task<string?> GetSelectionViaClipboardAsync()
    {
        DataObject? snapshot = TextInjector.SnapshotClipboard();
        uint before = NativeMethods.GetClipboardSequenceNumber();

        SyntheticKeyboard.SendCtrlC();
        await Task.Delay(180); // let the target app service WM_COPY

        string? text = null;
        try
        {
            if (NativeMethods.GetClipboardSequenceNumber() != before && Clipboard.ContainsText())
            {
                text = Clipboard.GetText();
            }
        }
        catch (Exception ex)
        {
            Log.D("selection clipboard read failed: " + ex.Message);
        }

        try
        {
            if (snapshot != null)
            {
                Clipboard.SetDataObject(snapshot, true);
            }
        }
        catch
        {
            // best effort restore
        }

        return string.IsNullOrWhiteSpace(text) ? null : text;
    }
}
