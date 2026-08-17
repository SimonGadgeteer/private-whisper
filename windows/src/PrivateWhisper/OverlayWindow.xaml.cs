using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace PrivateWhisper;

/// <summary>
/// Borderless, topmost, click-through status pill (the Mac notch capsule
/// equivalent): red dot + live level bars while recording, "Transcribing…"
/// while processing, brief flashes for success/info.
///
/// Placement: default is horizontally centered at the top edge of the PRIMARY
/// display with a ~12px gap. The user can reposition it via Settings →
/// "Move overlay…", which enters a draggable preview state (click-through
/// temporarily removed); on Done the position is stored in config as
/// virtual-screen coordinates and clamped to the visible bounds on every
/// restore in case monitors changed.
///
/// Click-through/no-activate is enforced with WS_EX_TRANSPARENT |
/// WS_EX_NOACTIVATE so the overlay can never steal input while dictating.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int BarCount = 12;
    private const double TopGap = 12;

    private readonly ConfigStore configStore;
    private readonly Rectangle[] bars = new Rectangle[BarCount];
    private readonly float[] recentLevels = new float[BarCount];
    private readonly DispatcherTimer hideTimer;

    private bool movePreviewActive;
    private bool clickThroughApplied;

    /// <summary>Mirrors config.OverlayEnabled; when false only ShowText (the
    /// injection-failure fallback) is displayed.</summary>
    public bool Enabled { get; set; } = true;

    public OverlayWindow(ConfigStore configStore)
    {
        this.configStore = configStore;
        InitializeComponent();

        for (int i = 0; i < BarCount; i++)
        {
            var bar = new Rectangle
            {
                Width = 3,
                Height = 4,
                RadiusX = 1.5,
                RadiusY = 1.5,
                Margin = new Thickness(1.5, 0, 1.5, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Fill = new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF)),
            };
            bars[i] = bar;
            LevelBars.Children.Add(bar);
        }

        hideTimer = new DispatcherTimer();
        hideTimer.Tick += (_, _) =>
        {
            hideTimer.Stop();
            if (!movePreviewActive) Hide();
        };

        SizeChanged += (_, _) => Reposition();
        SourceInitialized += (_, _) => ApplyClickThrough(true);
    }

    // ---- Window styles ----

    private void ApplyClickThrough(bool clickThrough)
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        long exStyle = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        exStyle |= NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE;
        if (clickThrough)
        {
            exStyle |= NativeMethods.WS_EX_TRANSPARENT;
        }
        else
        {
            exStyle &= ~NativeMethods.WS_EX_TRANSPARENT;
        }
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(exStyle));
        clickThroughApplied = clickThrough;
    }

    // ---- Placement ----

    private void Reposition()
    {
        if (movePreviewActive) return; // the user is placing it
        double width = ActualWidth > 0 ? ActualWidth : 200;
        double height = ActualHeight > 0 ? ActualHeight : 40;

        AppConfig config = configStore.Config;
        if (config.OverlayX is double x && config.OverlayY is double y)
        {
            // Clamp stored coordinates to the current virtual screen so the
            // overlay stays reachable after monitor layout changes.
            double minX = SystemParameters.VirtualScreenLeft;
            double minY = SystemParameters.VirtualScreenTop;
            double maxX = minX + SystemParameters.VirtualScreenWidth - width;
            double maxY = minY + SystemParameters.VirtualScreenHeight - height;
            Left = Math.Min(Math.Max(x, minX), Math.Max(minX, maxX));
            Top = Math.Min(Math.Max(y, minY), Math.Max(minY, maxY));
        }
        else
        {
            // Default: top-center of the primary display (Mac-notch muscle memory).
            Left = (SystemParameters.PrimaryScreenWidth - width) / 2;
            Top = TopGap;
        }
    }

    private void ShowPill()
    {
        Reposition();
        if (!IsVisible) Show();
    }

    // ---- Public state API (call on the UI thread) ----

    public void ShowRecording()
    {
        if (!Enabled) return;
        ExitMovePreviewVisuals();
        hideTimer.Stop();
        Array.Clear(recentLevels);
        RecordingDot.Visibility = Visibility.Visible;
        LevelBars.Visibility = Visibility.Visible;
        MessageText.Text = "";
        MessageText.Visibility = Visibility.Collapsed;
        ShowPill();
    }

    public void UpdateLevel(float rms)
    {
        if (!Enabled || !IsVisible || LevelBars.Visibility != Visibility.Visible) return;
        // Shift register of the most recent chunk levels.
        for (int i = 0; i < BarCount - 1; i++)
        {
            recentLevels[i] = recentLevels[i + 1];
        }
        recentLevels[BarCount - 1] = rms;
        for (int i = 0; i < BarCount; i++)
        {
            double normalized = Math.Min(1.0, recentLevels[i] * 25.0);
            bars[i].Height = 4 + normalized * 16;
        }
    }

    public void ShowProcessing(string message)
    {
        if (!Enabled) return;
        hideTimer.Stop();
        RecordingDot.Visibility = Visibility.Collapsed;
        LevelBars.Visibility = Visibility.Collapsed;
        MessageText.Text = message;
        MessageText.Visibility = Visibility.Visible;
        ShowPill();
    }

    public void Flash(string message, double seconds)
    {
        if (!Enabled) return;
        RecordingDot.Visibility = Visibility.Collapsed;
        LevelBars.Visibility = Visibility.Collapsed;
        MessageText.Text = message;
        MessageText.Visibility = Visibility.Visible;
        ShowPill();
        StartHideTimer(seconds);
    }

    public void FlashSuccess()
    {
        if (!Enabled)
        {
            Hide();
            return;
        }
        RecordingDot.Visibility = Visibility.Collapsed;
        LevelBars.Visibility = Visibility.Collapsed;
        MessageText.Text = "✓ Inserted";
        MessageText.Visibility = Visibility.Visible;
        ShowPill();
        StartHideTimer(1.2);
    }

    /// <summary>Injection-failure fallback — always shown, even when the
    /// overlay is disabled, so the dictation is never silently lost.</summary>
    public void ShowText(string reason)
    {
        RecordingDot.Visibility = Visibility.Collapsed;
        LevelBars.Visibility = Visibility.Collapsed;
        MessageText.Text = reason;
        MessageText.Visibility = Visibility.Visible;
        HintText.Text = "Your dictation was kept — tray icon → Copy Last Dictation.";
        HintText.Visibility = Visibility.Visible;
        ShowPill();
        StartHideTimer(8);
    }

    public void HideOverlay()
    {
        if (movePreviewActive) return;
        hideTimer.Stop();
        Hide();
    }

    private void StartHideTimer(double seconds)
    {
        hideTimer.Stop();
        hideTimer.Interval = TimeSpan.FromSeconds(seconds);
        hideTimer.Start();
    }

    // ---- Movable placement (Settings → "Move overlay…") ----

    public void EnterMovePreview()
    {
        movePreviewActive = true;
        hideTimer.Stop();
        RecordingDot.Visibility = Visibility.Visible;
        LevelBars.Visibility = Visibility.Collapsed;
        MessageText.Text = "Overlay position";
        MessageText.Visibility = Visibility.Visible;
        HintText.Text = "Drag me anywhere (any monitor), then click Done.";
        HintText.Visibility = Visibility.Visible;
        DoneButton.Visibility = Visibility.Visible;

        // Position at the stored/default spot before enabling dragging.
        movePreviewActive = false;
        Reposition();
        movePreviewActive = true;

        if (!IsVisible) Show();
        ApplyClickThrough(false);
    }

    public void ExitMovePreview(bool persistPosition)
    {
        if (!movePreviewActive) return;
        if (persistPosition)
        {
            double x = Left;
            double y = Top;
            configStore.Update(c =>
            {
                c.OverlayX = x;
                c.OverlayY = y;
            });
        }
        movePreviewActive = false;
        ExitMovePreviewVisuals();
        ApplyClickThrough(true);
        Hide();
    }

    /// <summary>Clears the stored position; the overlay returns to the default
    /// top-center of the primary display.</summary>
    public void ResetPosition()
    {
        configStore.Update(c =>
        {
            c.OverlayX = null;
            c.OverlayY = null;
        });
        if (movePreviewActive)
        {
            movePreviewActive = false;
            Reposition();
            movePreviewActive = true;
        }
        else if (IsVisible)
        {
            Reposition();
        }
    }

    private void ExitMovePreviewVisuals()
    {
        HintText.Visibility = Visibility.Collapsed;
        HintText.Text = "";
        DoneButton.Visibility = Visibility.Collapsed;
        if (!clickThroughApplied && !movePreviewActive)
        {
            ApplyClickThrough(true);
        }
    }

    private void RootBorder_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (movePreviewActive && e.ButtonState == MouseButtonState.Pressed)
        {
            try
            {
                DragMove();
            }
            catch (InvalidOperationException)
            {
                // Button released before DragMove could start — ignore.
            }
        }
    }

    private void DoneButton_Click(object sender, RoutedEventArgs e)
    {
        ExitMovePreview(persistPosition: true);
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // The overlay lives for the whole app session; hide instead of closing
        // unless the application is shutting down.
        base.OnClosing(e);
    }
}
