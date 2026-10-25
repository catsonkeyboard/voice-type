using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using VoiceType.Services;

namespace VoiceType.UI;

/// <summary>
/// 第三方应用第一次请求 VoiceType 听写时的授权弹窗（对应 macOS BridgePermissionPrompt.swift）。
/// 这是联动里唯一会抢焦点的地方：只在某个回调地址第一次出现时弹一次，之后按记住的选择处理。
/// 托盘应用没有前台窗口：弹窗必须置顶并激活，否则会落在其他窗口后面。
/// </summary>
public static class BridgePermissionPrompt
{
    /// <summary>
    /// 弹窗询问是否允许。返回 true 允许、false 拒绝；没有应用能接收这个回调时返回 null（不弹窗）。
    /// 必须在 UI 线程调用（模态对话框）。
    /// </summary>
    public static bool? Ask(string callback)
    {
        BridgeHandlerApp? handler = BridgeTransport.FindHandler(callback);
        if (handler is null)
            return null;

        var window = new Window
        {
            Title = "VoiceType 第三方应用联动",
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = true,
            Topmost = true,
            ShowActivated = true,
            MinWidth = 420,
            MaxWidth = 520,
        };
        if (handler.ExePath is not null && TryLoadIcon(handler.ExePath, out ImageSource? icon))
            window.Icon = icon;

        var text = new TextBlock
        {
            Text =
                $"「{handler.Name}」请求使用 VoiceType 听写\n\n" +
                "允许后，它可以让 VoiceType 开始录音，并接收识别出的文字。" +
                "录音时屏幕上会显示录音提示。\n\n" +
                $"回调地址：{callback}\n\n" +
                "之后可在 设置 → 通用 → 第三方应用 中撤销。",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(16),
        };
        var allow = new Button { Content = "允许", Padding = new Thickness(20, 4, 20, 4), MinWidth = 88 };
        var deny = new Button { Content = "拒绝", Padding = new Thickness(20, 4, 20, 4), MinWidth = 88 };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 0, 16, 16),
        };
        buttons.Children.Add(deny);
        buttons.Children.Add(allow);
        buttons.Children.Add(new System.Windows.Controls.Border { Width = 12 });

        var root = new StackPanel();
        root.Children.Add(text);
        root.Children.Add(buttons);
        window.Content = root;

        bool? result = null;
        allow.Click += (_, _) => { result = true; window.Close(); };
        deny.Click += (_, _) => { result = false; window.Close(); };
        // 直接关掉窗口（Alt+F4 等）没有做出选择：按拒绝处理，宁严勿松
        window.Closing += (_, _) => result ??= false;

        window.Loaded += (_, _) => window.Activate();
        window.ShowDialog();
        return result;
    }

    private static bool TryLoadIcon(string exePath, out ImageSource? icon)
    {
        icon = null;
        try
        {
            using System.Drawing.Icon extracted =
                System.Drawing.Icon.ExtractAssociatedIcon(exePath);
            if (extracted is null)
                return false;
            icon = Imaging.CreateBitmapSourceFromHIcon(
                extracted.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            icon.Freeze();
            return true;
        }
        catch
        {
            return false;
        }
    }
}
