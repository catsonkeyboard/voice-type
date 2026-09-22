using System.Windows.Threading;
using VoiceType.Interop;

namespace VoiceType.Services;

public enum InjectResult
{
    Injected,
    CopiedToClipboard,
}

/// <summary>
/// 把文本注入前台 App 光标处：写剪贴板 → 合成 Ctrl+V → 稍后恢复原剪贴板。
/// Windows 上无需任何系统授权（对应 macOS 需辅助功能权限的差异见 MIGRATION.md §3.3）。
/// 已知边界：UIPI 限制导致无法注入以管理员运行的前台窗口；此时自动降级为仅复制。
/// 必须在 UI(STA) 线程调用。
/// </summary>
public static class TextInjector
{
    /// <summary>Windows 无辅助功能授权概念，恒为 true（保留 API 形状与 macOS 对齐）。</summary>
    public static bool IsTrusted => true;

    /// <summary>打开系统「麦克风隐私」设置页（迁移版替代原「去授权」按钮的去向）。</summary>
    public static void OpenMicrophonePrivacySettings() =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "ms-settings:privacy-microphone",
            UseShellExecute = true,
        });

    public static InjectResult Inject(string text)
    {
        string? saved = TryGetClipboard();
        if (!TrySetClipboard(text))
            return InjectResult.CopiedToClipboard;  // 剪贴板都写不进去的极端场景

        bool sent = WinInput.TapKey(WinInput.VkV, WinInput.VkControl);
        if (!sent)
            return InjectResult.CopiedToClipboard;

        if (saved is not null)
        {
            // 600ms 后恢复原剪贴板（给目标应用留出粘贴读取时间）
            var timer = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMilliseconds(600),
            };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                TrySetClipboard(saved);
            };
            timer.Start();
        }
        return InjectResult.Injected;
    }

    private static string? TryGetClipboard()
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                return System.Windows.Clipboard.ContainsText()
                    ? System.Windows.Clipboard.GetText()
                    : null;
            }
            catch
            {
                // CLIPBRD_E_CANCELED：剪贴板被其他进程占用，重试一次
                Thread.Sleep(30);
            }
        }
        return null;
    }

    private static bool TrySetClipboard(string text)
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                System.Windows.Clipboard.SetDataObject(text, true);
                return true;
            }
            catch
            {
                Thread.Sleep(30);
            }
        }
        return false;
    }
}
