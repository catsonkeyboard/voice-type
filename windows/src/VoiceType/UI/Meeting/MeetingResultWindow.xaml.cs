using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using VoiceType.Core;
using VoiceType.Models;

namespace VoiceType.UI.Meeting;

/// <summary>会议转写结果窗口：分段展示、说话人改名、复制/导出、生成纪要。</summary>
public partial class MeetingResultWindow : Window
{
    private static readonly Brush[] SpeakerBrushes =
    [
        CreateBrush(0xE1, 0xEF, 0xFF),
        CreateBrush(0xDA, 0xF7, 0xE6),
        CreateBrush(0xFF, 0xF0, 0xD4),
        CreateBrush(0xF0, 0xE8, 0xFF),
        CreateBrush(0xFF, 0xE3, 0xEE),
        CreateBrush(0xD9, 0xF3, 0xF3),
        CreateBrush(0xFF, 0xE4, 0xE6),
        CreateBrush(0xE5, 0xE9, 0xFF),
    ];

    private static Brush CreateBrush(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    private sealed class SegmentRow
    {
        public required string SpeakerLabel { get; init; }
        public required Brush SpeakerBrush { get; init; }
        public required string TimestampText { get; init; }
        public required string Text { get; init; }
        public required int Speaker { get; init; }
    }

    public static void ShowResult(string jsonPath)
    {
        var window = new MeetingResultWindow(jsonPath);
        window.Show();
        window.Activate();
    }

    private readonly AppDependencies _deps = AppDependencies.Shared;
    private readonly string _jsonPath;
    private MeetingTranscript? _transcript;
    private string? _minutes;

    private MeetingResultWindow(string jsonPath)
    {
        InitializeComponent();
        _jsonPath = jsonPath;
        _transcript = MeetingTranscript.Load(jsonPath);
        Refresh();
    }

    private void Refresh()
    {
        if (_transcript is null)
        {
            MetaText.Text = "无法加载会议稿";
            SegmentList.ItemsSource = null;
            return;
        }
        MeetingTranscript t = _transcript;
        MetaText.Text =
            $"{t.CreatedAt:yyyy-MM-dd HH:mm} · 时长 {MeetingTranscript.Timestamp(t.Duration)} · {t.SpeakerIds.Count} 位说话人";
        DegradedHint.Visibility = t.Degraded ? Visibility.Visible : Visibility.Collapsed;
        SegmentList.ItemsSource = t.Segments.Select(s => new SegmentRow
        {
            Speaker = s.Speaker,
            SpeakerLabel = t.DisplayName(s.Speaker),
            SpeakerBrush = SpeakerBrushes[Math.Abs(s.Speaker) % SpeakerBrushes.Length],
            TimestampText = MeetingTranscript.Timestamp(s.Start),
            Text = s.Text,
        }).ToList();
    }

    private void OnRenameSpeaker(object sender, RoutedEventArgs e)
    {
        if (_transcript is null ||
            (sender as Button)?.CommandParameter is not int speaker)
            return;
        string current = _transcript.SpeakerNames.TryGetValue(speaker, out string? n) ? n : "";

        var dialog = new Window
        {
            Title = "说话人改名",
            Width = 320,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
        };
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock
        {
            Text = $"将「{_transcript.DisplayName(speaker)}」改为新名字，全文生效（留空恢复默认）:",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        var box = new TextBox { Text = current };
        panel.Children.Add(box);
        var ok = new Button { Content = "确定", Width = 80, Margin = new Thickness(0, 12, 0, 0) };
        panel.Children.Add(ok);
        dialog.Content = panel;
        ok.Click += (_, _) => dialog.DialogResult = true;
        box.Focus();

        if (dialog.ShowDialog() == true)
        {
            string name = box.Text.Trim();
            if (name.Length == 0)
                _transcript.SpeakerNames.Remove(speaker);
            else
                _transcript.SpeakerNames[speaker] = name;
            _transcript.Save(_jsonPath);
            Refresh();
        }
    }

    private void OnCopyAll(object sender, RoutedEventArgs e)
    {
        if (_transcript is not null)
            TrySetClipboard(_transcript.Markdown());
    }

    private void OnExportMarkdown(object sender, RoutedEventArgs e)
    {
        if (_transcript is null)
            return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "导出 Markdown",
            Filter = "Markdown|*.md",
            FileName = System.IO.Path.GetFileNameWithoutExtension(_jsonPath) + ".md",
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                File.WriteAllText(dialog.FileName, _transcript.Markdown());
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"导出失败：{ex.Message}", "VoiceType",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }

    private async void OnGenerateMinutes(object sender, RoutedEventArgs e)
    {
        if (_transcript is null)
            return;
        MinutesButton.IsEnabled = false;
        MinutesError.Visibility = Visibility.Collapsed;
        string? result = await _deps.Polish.Complete(
            MinutesPrompt.System, MinutesPrompt.User(_transcript));
        MinutesButton.IsEnabled = true;
        if (result is null)
        {
            MinutesError.Text = "纪要生成失败：LLM 服务不可用（检查设置 → 润色）";
            MinutesError.Visibility = Visibility.Visible;
            return;
        }
        _minutes = result;
        MinutesText.Text = result;
        MinutesSeparator.Visibility = Visibility.Visible;
        MinutesSection.Visibility = Visibility.Visible;
    }

    private void OnCopyMinutes(object sender, RoutedEventArgs e)
    {
        if (_minutes is not null)
            TrySetClipboard(_minutes);
    }

    private static void TrySetClipboard(string text)
    {
        try
        {
            Clipboard.SetDataObject(text, true);
        }
        catch
        {
            // 剪贴板被占用，忽略
        }
    }
}
