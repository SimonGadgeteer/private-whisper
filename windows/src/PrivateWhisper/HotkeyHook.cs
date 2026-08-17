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

    private bool dictationDown;
    private bool commandDown;

    public event Action? DictationPressed;
    public event Action? DictationReleased;
    public event Action? CommandPressed;
    public event Action? CommandReleased;

    public HotkeyHook()
    {
        dispatcher = Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
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
        if (dictationDown)
        {
            dictationDown = false;
            Dispatch(DictationReleased);
        }
        if (commandDown)
        {
            commandDown = false;
            Dispatch(CommandReleased);
        }
        dictationVk = dictationKey;
        commandVk = commandKey;
    }

    public void Stop()
    {
        if (hookHandle != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(hookHandle);
            hookHandle = IntPtr.Zero;
        }
        hookProc = null;
        if (dictationDown)
        {
            dictationDown = false;
            Dispatch(DictationReleased);
        }
        if (commandDown)
        {
            commandDown = false;
            Dispatch(CommandReleased);
        }
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
                    // Key-repeat sends additional key-downs while held; the
                    // isDown/state check makes press fire exactly once.
                    if (isDown && !dictationDown)
                    {
                        dictationDown = true;
                        Dispatch(DictationPressed);
                    }
                    else if (isUp && dictationDown)
                    {
                        dictationDown = false;
                        Dispatch(DictationReleased);
                    }
                }
                else if (commandVk.HasValue && data.vkCode == commandVk.Value)
                {
                    if (isDown && !commandDown)
                    {
                        commandDown = true;
                        Dispatch(CommandPressed);
                    }
                    else if (isUp && commandDown)
                    {
                        commandDown = false;
                        Dispatch(CommandReleased);
                    }
                }
            }
        }
        return NativeMethods.CallNextHookEx(hookHandle, nCode, wParam, lParam);
    }

    private void Dispatch(Action? handler)
    {
        if (handler == null) return;
        dispatcher.BeginInvoke(handler);
    }
}
