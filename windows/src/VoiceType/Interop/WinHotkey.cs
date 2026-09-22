using System.Runtime.InteropServices;

namespace VoiceType.Interop;

/// <summary>RegisterHotKey / WM_HOTKEY 相关 P/Invoke。</summary>
internal static class WinHotkey
{
    public const int WmHotkey = 0x0312;

    [Flags]
    public enum Modifiers : uint
    {
        None = 0,
        Alt = 0x0001,
        Control = 0x0002,
        Shift = 0x0004,
        Win = 0x0008,
        /// <summary>按住不放不重复触发</summary>
        NoRepeat = 0x4000,
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, Modifiers modifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
