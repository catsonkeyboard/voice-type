using System.Runtime.InteropServices;
using System.Windows.Interop;
using VoiceType.Interop;
using VoiceType.Models;


namespace VoiceType.Services;

/// <summary>
/// 全局热键（RegisterHotKey + 消息专用窗口）。应用生命周期内单例，
/// 切换组合键时先注销再注册。对应 macOS Carbon RegisterEventHotKey。
/// </summary>
public sealed class HotkeyManager : IDisposable
{
    public static readonly HotkeyManager Shared = new();

    private const int HotkeyId = 0x5654;  // 'VT'

    /// <summary>回调在 UI 线程派发</summary>
    public event Action? OnHotkey;

    private HwndSource? _source;
    private SynchronizationContext _ui = new SynchronizationContext();

    private HotkeyManager() { }

    /// <summary>注册组合键（旧组合自动注销）。返回 false 表示注册失败（组合被占用等）。</summary>
    public bool Register(KeyCombo combo)
    {
        EnsureWindow();
        Unregister();
        var modifiers = (WinHotkey.Modifiers)combo.Modifiers | WinHotkey.Modifiers.NoRepeat;
        if (!WinHotkey.RegisterHotKey(_source!.Handle, HotkeyId, modifiers, combo.VirtualKey))
            return false;
        return true;
    }

    public void Unregister()
    {
        if (_source is null)
            return;
        WinHotkey.UnregisterHotKey(_source.Handle, HotkeyId);
    }

    private void EnsureWindow()
    {
        if (_source is not null)
            return;
        _ui = SynchronizationContext.Current ?? new SynchronizationContext();
        var parameters = new HwndSourceParameters("VoiceTypeHotkey")
        {
            ParentWindow = new IntPtr(-3),  // HWND_MESSAGE：消息专用，不可见
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WinHotkey.WmHotkey && wParam.ToInt32() == HotkeyId)
        {
            handled = true;
            _ui.Post(_ => OnHotkey?.Invoke(), null);
            return IntPtr.Zero;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Unregister();
        _source?.RemoveHook(WndProc);
        _source = null;
    }
}
