using System.Runtime.InteropServices;

namespace VoiceType.Interop;

/// <summary>SendInput 键盘合成（P/Invoke 声明与 INPUT 结构）。</summary>
internal static class WinInput
{
    public const uint InputKeyboard = 1;
    public const uint KeyEventKeyDown = 0x0000;
    public const uint KeyEventKeyUp = 0x0002;
    public const ushort VkControl = 0x11;
    public const ushort VkV = 0x56;

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

    /// <summary>合成一次按键（按下 + 抬起）。modifiers 为按下期间保持的修饰键 VK。</summary>
    public static bool TapKey(ushort vk, params ushort[] heldModifiers)
    {
        var inputs = new List<INPUT>(heldModifiers.Length * 2 + 2);
        foreach (ushort mod in heldModifiers)
        {
            inputs.Add(Key(mod, KeyEventKeyDown));
        }
        inputs.Add(Key(vk, KeyEventKeyDown));
        inputs.Add(Key(vk, KeyEventKeyUp));
        foreach (ushort mod in heldModifiers.Reverse())
        {
            inputs.Add(Key(mod, KeyEventKeyUp));
        }
        uint sent = SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
        return sent == inputs.Count;
    }

    private static INPUT Key(ushort vk, uint flags) => new()
    {
        type = InputKeyboard,
        u = new InputUnion
        {
            ki = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = flags, time = 0, dwExtraInfo = IntPtr.Zero },
        },
    };
}
