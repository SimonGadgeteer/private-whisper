using System.Runtime.InteropServices;

namespace PrivateWhisper;

/// <summary>Synthetic key chords via SendInput (the CGEvent Cmd+V equivalent).
/// Injected events carry LLKHF_INJECTED, so our own keyboard hook ignores them.</summary>
internal static class SyntheticKeyboard
{
    private const ushort VK_V = 0x56;
    private const ushort VK_C = 0x43;

    public static void SendCtrlV() => SendChord((ushort)NativeMethods.VK_CONTROL, VK_V);

    public static void SendCtrlC() => SendChord((ushort)NativeMethods.VK_CONTROL, VK_C);

    private static void SendChord(ushort modifier, ushort key)
    {
        var inputs = new NativeMethods.INPUT[4];
        inputs[0] = KeyInput(modifier, keyUp: false);
        inputs[1] = KeyInput(key, keyUp: false);
        inputs[2] = KeyInput(key, keyUp: true);
        inputs[3] = KeyInput(modifier, keyUp: true);
        uint sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.INPUT>());
        if (sent != inputs.Length)
        {
            Log.D($"SendInput sent {sent}/{inputs.Length} events, error={Marshal.GetLastWin32Error()}");
        }
    }

    private static NativeMethods.INPUT KeyInput(ushort vk, bool keyUp)
    {
        return new NativeMethods.INPUT
        {
            type = NativeMethods.INPUT_KEYBOARD,
            U = new NativeMethods.InputUnion
            {
                ki = new NativeMethods.KEYBDINPUT
                {
                    wVk = vk,
                    wScan = 0,
                    dwFlags = keyUp ? NativeMethods.KEYEVENTF_KEYUP : 0,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero,
                },
            },
        };
    }
}
