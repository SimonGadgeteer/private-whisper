using System.Windows.Threading;
using SD = System.Drawing;
using WF = System.Windows.Forms;

namespace PrivateWhisper;

/// <summary>
/// System tray icon + menu (the NSStatusItem equivalent). Colored dot icons
/// are drawn at runtime so no binary assets are needed:
/// gray = idle, red = recording, orange = processing, green = injected,
/// yellow = warning. Transient states auto-revert to idle.
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly WF.NotifyIcon notifyIcon;
    private readonly WF.ToolStripMenuItem statusMenuItem;
    private readonly WF.ToolStripMenuItem copyLastMenuItem;
    private readonly Dictionary<PipelineState, SD.Icon> icons = new();
    private readonly List<IntPtr> iconHandles = new();
    private readonly DispatcherTimer revertTimer;

    public PipelineState State { get; private set; } = PipelineState.Idle;

    public string? LastDictation { get; set; }

    // Wired by App.
    public Action? OpenSettings;
    public Action? OpenStats;
    public Action? OpenDictionary;
    public Action? OpenModels;
    public Action? QuitRequested;

    public TrayController()
    {
        foreach ((PipelineState state, SD.Color color) in new[]
        {
            (PipelineState.Idle, SD.Color.FromArgb(140, 140, 140)),
            (PipelineState.Recording, SD.Color.FromArgb(229, 57, 53)),
            (PipelineState.Processing, SD.Color.FromArgb(251, 140, 0)),
            (PipelineState.Injected, SD.Color.FromArgb(67, 160, 71)),
            (PipelineState.Warning, SD.Color.FromArgb(253, 216, 53)),
        })
        {
            icons[state] = CreateDotIcon(color);
        }

        statusMenuItem = new WF.ToolStripMenuItem("Idle") { Enabled = false };
        copyLastMenuItem = new WF.ToolStripMenuItem("Copy Last Dictation", null, (_, _) => CopyLastDictation())
        {
            Enabled = false,
        };

        var menu = new WF.ContextMenuStrip();
        menu.Items.Add(statusMenuItem);
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add(copyLastMenuItem);
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add(new WF.ToolStripMenuItem("Settings…", null, (_, _) => OpenSettings?.Invoke()));
        menu.Items.Add(new WF.ToolStripMenuItem("Statistics…", null, (_, _) => OpenStats?.Invoke()));
        menu.Items.Add(new WF.ToolStripMenuItem("Dictionary…", null, (_, _) => OpenDictionary?.Invoke()));
        menu.Items.Add(new WF.ToolStripMenuItem("Models…", null, (_, _) => OpenModels?.Invoke()));
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add(new WF.ToolStripMenuItem("Quit Private Whisper", null, (_, _) => QuitRequested?.Invoke()));

        notifyIcon = new WF.NotifyIcon
        {
            Icon = icons[PipelineState.Idle],
            Text = "Private Whisper — idle",
            ContextMenuStrip = menu,
            Visible = true,
        };
        notifyIcon.DoubleClick += (_, _) => OpenSettings?.Invoke();

        revertTimer = new DispatcherTimer();
        revertTimer.Tick += (_, _) =>
        {
            revertTimer.Stop();
            if (State is PipelineState.Injected or PipelineState.Warning)
            {
                SetState(PipelineState.Idle);
            }
        };
    }

    public void SetState(PipelineState state, string? message = null)
    {
        State = state;
        string label = state switch
        {
            PipelineState.Idle => "Idle — hold the hotkey to dictate",
            PipelineState.Recording => "Recording…",
            PipelineState.Processing => "Processing…",
            PipelineState.Injected => "Inserted",
            PipelineState.Warning => message ?? "Warning",
            _ => "Idle",
        };
        statusMenuItem.Text = label;
        copyLastMenuItem.Enabled = LastDictation != null;
        notifyIcon.Icon = icons[state];
        // NotifyIcon.Text must stay under 64 chars.
        string tooltip = "Private Whisper — " + label;
        notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip[..63];

        revertTimer.Stop();
        if (state is PipelineState.Injected or PipelineState.Warning)
        {
            revertTimer.Interval = TimeSpan.FromSeconds(state == PipelineState.Injected ? 3 : 6);
            revertTimer.Start();
        }
    }

    public void ShowSuggestionBalloon(IReadOnlyList<string> terms)
    {
        try
        {
            notifyIcon.ShowBalloonTip(
                4000,
                "Dictionary suggestions",
                string.Join(", ", terms) + " — open Dictionary… in the tray menu to add.",
                WF.ToolTipIcon.Info);
        }
        catch
        {
            // Balloon suppressed by focus assist etc. — not important.
        }
    }

    private void CopyLastDictation()
    {
        if (LastDictation is string text)
        {
            TextInjector.TrySetClipboardText(text);
        }
    }

    private SD.Icon CreateDotIcon(SD.Color color)
    {
        using var bitmap = new SD.Bitmap(16, 16);
        using (var graphics = SD.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SD.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(SD.Color.Transparent);
            using var fill = new SD.SolidBrush(color);
            graphics.FillEllipse(fill, 2, 2, 12, 12);
            using var ring = new SD.Pen(SD.Color.FromArgb(90, 0, 0, 0), 1);
            graphics.DrawEllipse(ring, 2, 2, 12, 12);
        }
        IntPtr hIcon = bitmap.GetHicon();
        iconHandles.Add(hIcon);
        return SD.Icon.FromHandle(hIcon);
    }

    public void Dispose()
    {
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        foreach (IntPtr handle in iconHandles)
        {
            NativeMethods.DestroyIcon(handle);
        }
        iconHandles.Clear();
    }
}
