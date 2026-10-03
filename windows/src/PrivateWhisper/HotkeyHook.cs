using Application = System.Windows.Application;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace PrivateWhisper;

/// <summary>
/// Push-to-talk detection via a low-level keyboard hook (WH_KEYBOARD_LL) —
/// the only Windows mechanism that sees both key-down AND key-up globally
/// (RegisterHotKey cannot report releases). No permission grants needed.
///
/// Must be created and started on the WPF UI thread: the hook callback is
/// delivered through that thread's message pump. Handlers are dispatched
/// asynchronously so the hook procedure itself returns immediately (Windows
/// silently removes hooks that exceed the LowLevelHooksTimeout).
/// </summary>
public sealed class HotkeyHook : IDisposable
{
    private IntPtr hookHandle = IntPtr.Zero;

    // Keep a strong reference to the delegate: if it is GC'd while the hook is
    // installed the process crashes — the classic SetWindowsHookEx bug.
    private NativeMethods.LowLevelKeyboardProc? hookProc;

    private readonly Dispatcher dispatcher;

    private uint dictationVk = NativeMethods.VK_RMENU;
    private uint? commandVk = NativeMethods.VK_RCONTROL;

    // Hold delay + key-combination detection per key (see HoldGesture): AltGr is Right Alt, and
    // AltGr+2 is "@" on Swiss/German layouts.
    private readonly HoldGesture dictation = new();
    private readonly HoldGesture command = new();
    private readonly DispatcherTimer dictationTimer;
    private readonly DispatcherTimer commandTimer;

    /// <summary>How long a push-to-talk key must be held, with nothing else pressed, before recording starts.</summary>
    public TimeSpan HoldDelay { get; set; } = TimeSpan.FromMilliseconds(250);

    public event Action? DictationPressed;
    public event Action? DictationReleased;
    public event Action? DictationCancelled;
    public event Action? CommandPressed;
    public event Action? CommandReleased;
    public event Action? CommandCancelled;

    public HotkeyHook()
    {
        dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        dictationTimer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher);
        dictationTimer.Tick += (_, _) => { dictationTimer.Stop(); Apply(dictation, dictation.HoldDelayElapsed(), isCommand: false); };
        commandTimer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher);
        commandTimer.Tick += (_, _) => { commandTimer.Stop(); Apply(command, command.HoldDelayElapsed(), isCommand: true); };
    }

    public void Start(uint dictationKey, uint? commandKey)
    {
        Stop();
        dictationVk = dictationKey;
        commandVk = commandKey;
        hookProc = HookCallback;
        hookHandle = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_KEYBOARD_LL, hookProc,
            NativeMethods.GetModuleHandle(null), 0);
        if (hookHandle == IntPtr.Zero)
        {
            Log.D("HotkeyHook: SetWindowsHookEx failed, error=" + Marshal.GetLastWin32Error());
        }
        else
        {
            Log.D($"HotkeyHook started: dictation=0x{dictationVk:X2} command={(commandVk.HasValue ? $"0x{commandVk.Value:X2}" : "disabled")}");
        }
    }

    /// <summary>Re-arms the hook for new key choices. If a key is held during
    /// the change, its release is fired so a recording never gets stuck.</summary>
    public void UpdateKeys(uint dictationKey, uint? commandKey)
    {
        ReleaseAll();
        dictationVk = dictationKey;
        commandVk = commandKey;
    }

    private void ReleaseAll()
    {
        Apply(dictation, dictation.KeyUp(), isCommand: false);
        Apply(command, command.KeyUp(), isCommand: true);
    }

    public void Stop()
    {
        if (hookHandle != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(hookHandle);
            hookHandle = IntPtr.Zero;
        }
        hookProc = null;
        ReleaseAll();
    }

    public void Dispose() => Stop();

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var data = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
            // Ignore our own SendInput events (synthetic Ctrl+V/Ctrl+C).
            if ((data.flags & NativeMethods.LLKHF_INJECTED) == 0)
            {
                long msg = wParam.ToInt64();
                bool isDown = msg == NativeMethods.WM_KEYDOWN || msg == NativeMethods.WM_SYSKEYDOWN;
                bool isUp = msg == NativeMethods.WM_KEYUP || msg == NativeMethods.WM_SYSKEYUP;

                if (data.vkCode == dictationVk)
                {
                    if (isDown) Apply(dictation, dictation.KeyDown(), isCommand: false);
                    else if (isUp) Apply(dictation, dictation.KeyUp(), isCommand: false);
                }
                else if (commandVk.HasValue && data.vkCode == commandVk.Value)
                {
                    if (isDown) Apply(command, command.KeyDown(), isCommand: true);
                    else if (isUp) Apply(command, command.KeyUp(), isCommand: true);
                }
                else if (isDown && !IsAltGrFakeControl(data))
                {
                    bool modifierOnly = IsModifier(data.vkCode);
                    Apply(dictation, dictation.OtherInput(modifierOnly), isCommand: false);
                    Apply(command, command.OtherInput(modifierOnly), isCommand: true);
                }
            }
        }
        return NativeMethods.CallNextHookEx(hookHandle, nCode, wParam, lParam);
    }

    /// <summary>AltGr makes Windows inject a fake Left Ctrl (scan code 0x21D) before each Right Alt
    /// key-down, including key repeat; it is not the user pressing another key.</summary>
    private static bool IsAltGrFakeControl(NativeMethods.KBDLLHOOKSTRUCT data) =>
        data.vkCode == NativeMethods.VK_LCONTROL && data.scanCode == 0x21D;

    private static bool IsModifier(uint vk) =>
        vk is 0x10 or 0x11 or 0x12 or 0x14 or (>= 0xA0 and <= 0xA5) or 0x5B or 0x5C;  // Shift/Ctrl/Alt/Caps/Win

    private void Apply(HoldGesture gesture, HoldGesture.Action action, bool isCommand)
    {
        DispatcherTimer timer = isCommand ? commandTimer : dictationTimer;
        switch (action)
        {
            case HoldGesture.Action.ScheduleActivation:
                if (HoldDelay <= TimeSpan.Zero)
                {
                    Apply(gesture, gesture.HoldDelayElapsed(), isCommand);
                    return;
                }
                timer.Stop();
                timer.Interval = HoldDelay;
                timer.Start();
                break;
            case HoldGesture.Action.CancelScheduled:
                timer.Stop();
                if (gesture.State == HoldGesture.Phase.Combination)
                    Log.D($"HotkeyHook: key combination on the {(isCommand ? "command" : "dictation")} key, not dictation");
                break;
            case HoldGesture.Action.Start:
                Dispatch(isCommand ? CommandPressed : DictationPressed);
                break;
            case HoldGesture.Action.Stop:
                Dispatch(isCommand ? CommandReleased : DictationReleased);
                break;
            case HoldGesture.Action.Cancel:
                Log.D($"HotkeyHook: key combination during {(isCommand ? "command" : "dictation")} recording, discarding");
                Dispatch(isCommand ? CommandCancelled : DictationCancelled);
                break;
        }
    }

    private void Dispatch(Action? handler)
    {
        if (handler == null) return;
        dispatcher.BeginInvoke(handler);
    }
}
