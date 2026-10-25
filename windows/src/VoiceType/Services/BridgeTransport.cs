using System.Diagnostics;
using Microsoft.Win32;

namespace VoiceType.Services;

/// <summary>
/// 第三方应用联动的平台接入：voicetype:// 的注册表注册、回调地址接收方解析、结果回传。
/// 对应 macOS 的 CFBundleURLTypes 注册 + NSWorkspace（AppDelegate.swift 里的 BridgeCallback.send）。
/// </summary>
public static class BridgeTransport
{
    public const string Scheme = "voicetype";
    /// <summary>单实例之间转发 URL 的命名管道（第二个实例把 URL 发给已在运行的实例）</summary>
    public const string PipeName = "VoiceTypeWinBridgePipe";

    /// <summary>
    /// 把结果回传给第三方应用：打开 &lt;callback&gt;?session=…&amp;text=…。
    /// 与 macOS 的差异：ShellExecute 打开自定义协议无法禁止目标应用被激活/抢焦点
    /// （macOS 有 NSWorkspace.OpenConfiguration.activates=false），这里接受该行为。
    /// 日志里不写回传内容。
    /// </summary>
    public static void Send(string callback, string session, BridgeOutcome outcome)
    {
        string url = BridgeCallback.Url(callback, session, outcome);
        try
        {
            using var process = Process.Start(new ProcessStartInfo(url)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception e)
        {
            Debug.WriteLine($"VoiceType: 回传第三方应用失败（{e.GetType().Name}）");
        }
    }

    /// <summary>
    /// 注册 voicetype:// 协议（HKCU 当前用户，无需管理员），幂等；
    /// 指向当前 exe。失败只记日志（联动不可用，应用其他功能不受影响）。
    /// </summary>
    public static void RegisterScheme()
    {
        try
        {
            using RegistryKey root = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{Scheme}");
            root.SetValue(null, $"URL:{Scheme}");
            root.SetValue("URL Protocol", "");
            using RegistryKey command = root.CreateSubKey(@"shell\open\command");
            command.SetValue(null, $"\"{Environment.ProcessPath}\" \"%1\"");
        }
        catch (Exception e)
        {
            Debug.WriteLine($"VoiceType: 注册 {Scheme}:// 协议失败（{e.GetType().Name}）");
        }
    }

    /// <summary>回调地址的接收方（能打开这个 scheme 的应用）；没有返回 null</summary>
    public static BridgeHandlerApp? FindHandler(string callback)
    {
        int colon = callback.IndexOf(':');
        if (colon <= 0)
            return null;
        string scheme = callback[..colon].ToLowerInvariant();
        try
        {
            // 当前用户优先，再看机器级（HKCR 已合并两者）
            using RegistryKey? key =
                Registry.CurrentUser.OpenSubKey($@"Software\Classes\{scheme}\shell\open\command")
                ?? Registry.ClassesRoot.OpenSubKey($@"{scheme}\shell\open\command");
            if (key?.GetValue(null) is not string command || command.Length == 0)
                return null;
            string? exe = ExtractExePath(command);
            string name = exe is not null && File.Exists(exe)
                ? FileVersionInfo.GetVersionInfo(exe).ProductName is { Length: > 0 } product
                    ? product
                    : Path.GetFileNameWithoutExtension(exe)
                : scheme;
            return new BridgeHandlerApp(name, exe);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>从「"C:\path\app.exe" "%1"」这类注册表命令里取出 exe 路径</summary>
    private static string? ExtractExePath(string command)
    {
        command = command.Trim();
        if (command.Length == 0)
            return null;
        if (command[0] == '"')
        {
            int end = command.IndexOf('"', 1);
            return end > 1 ? command[1..end] : null;
        }
        int space = command.IndexOf(' ');
        return (space < 0 ? command : command[..space]).TrimEnd('.');
    }
}

/// <summary>回调地址的接收方应用（授权弹窗显示用）</summary>
/// <param name="Name">显示名；解析不到回退为 scheme</param>
/// <param name="ExePath">可执行文件路径；解析不到为 null（图标显示不出来）</param>
public sealed record BridgeHandlerApp(string Name, string? ExePath);
