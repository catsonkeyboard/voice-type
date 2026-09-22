using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using VoiceType.Core;
using VoiceType.Models;
using VoiceType.UI.Meeting;
using VoiceType.Services;

namespace VoiceType.UI.Panel;

/// <summary>主面板（对应 macOS 菜单栏面板 PanelView；Windows 用常规窗口承载）。</summary>
public partial class PanelWindow : Window
{
    private static PanelWindow? _instance;
    private static readonly SolidColorBrush
        Green = new(Color.FromRgb(0x3F, 0xB9, 0x50)),
        Red = new(Color.FromRgb(0xE5, 0x48, 0x4D)),
        Blue = new(Color.FromRgb(0x2F, 0x6F, 0xDB)),
        Purple = new(Color.FromRgb(0x8B, 0x5C, 0xF6)),
        Orange = new(Color.FromRgb(0xD2, 0x99, 0x22));

    private readonly AppDependencies _deps = AppDependencies.Shared;
    private readonly DispatcherTimer _meetingClock = new() { Interval = TimeSpan.FromSeconds(1) };

    public static void ShowPanel()
    {
        if (_instance is null)
        {
            _instance = new PanelWindow();
        }
        _instance.Show();
        _instance.Activate();
    }

    private PanelWindow()
    {
        InitializeComponent();
        RefreshHistory();
        RefreshStatus();
        RefreshMeeting();
        RefreshFileJob();

        _deps.State.PropertyChanged += OnStateChanged;
        _meetingClock.Tick += (_, _) => RefreshMeetingClock();

        // 面板显示时刷新历史（与 macOS 端语义一致：状态变化/出现时重读）
        Activated += (_, _) => RefreshHistory();
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => OnStateChanged(sender, e));
            return;
        }
        switch (e.PropertyName)
        {
            case nameof(AppState.Phase):
                RefreshStatus();
                RefreshHistory();
                break;
            case nameof(AppState.FileJob):
            case nameof(AppState.FileJobText):
                RefreshFileJob();
                RefreshHistory();
                break;
            case nameof(AppState.Meeting):
            case nameof(AppState.MeetingStage):
            case nameof(AppState.MeetingProgress):
            case nameof(AppState.MeetingResultPath):
            case nameof(AppState.MeetingError):
                RefreshMeeting();
                break;
        }
    }

    // ----- 状态头 + 录音按钮 -----

    /// <summary>按当前引擎判断听写就绪：本地看模型，云端看 Key</summary>
    private bool EngineReady => _deps.Settings.AsrEngine switch
    {
        AsrEngine.Local => _deps.State.ModelsReady,
        AsrEngine.DashScope => _deps.Settings.DashScopeApiKey.Length > 0,
        _ => false,
    };

    private void RefreshStatus()
    {
        AppState state = _deps.State;
        if (!EngineReady)
        {
            StatusDot.Fill = Orange;
            StatusText.Text = _deps.Settings.AsrEngine == AsrEngine.Local
                ? $"模型未安装：{_deps.Settings.LocalAsrModel.Label()}（设置 → 识别 可切换）"
                : "未配置 DashScope API Key（设置 → 识别）";
        }
        else
        {
            StatusDot.Fill = state.Phase switch
            {
                AppState.PhaseKind.Idle => Green,
                AppState.PhaseKind.Recording => Red,
                AppState.PhaseKind.Transcribing => Blue,
                AppState.PhaseKind.Polishing => Purple,
                AppState.PhaseKind.Error => Orange,
                _ => Green,
            };
            StatusText.Text = state.Phase switch
            {
                AppState.PhaseKind.Idle => $"就绪 · 按 {_deps.Settings.KeyCombo.Display} 开始听写",
                AppState.PhaseKind.Recording => "录音中…再按快捷键结束",
                AppState.PhaseKind.Transcribing => "识别中…",
                AppState.PhaseKind.Polishing => "润色中…",
                AppState.PhaseKind.Error => state.PhaseError ?? "出错",
                _ => "",
            };
        }

        bool recording = state.Phase == AppState.PhaseKind.Recording;
        RecordButton.Content = recording ? "停止并转写" : "开始录音";
        if (recording)
        {
            RecordButton.Background = Red;
            RecordButton.Foreground = Brushes.White;
        }
        else
        {
            RecordButton.ClearValue(Button.BackgroundProperty);
            RecordButton.ClearValue(Button.ForegroundProperty);
        }
        RecordButton.IsEnabled = EngineReady && state.Phase is not (AppState.PhaseKind.Transcribing
            or AppState.PhaseKind.Polishing);
    }

    // ----- 会议区 -----

    private void RefreshMeeting()
    {
        AppState state = _deps.State;
        MeetingIdleRow.Visibility = state.Meeting is AppState.MeetingPhaseKind.Idle
            or AppState.MeetingPhaseKind.Failed ? Visibility.Visible : Visibility.Collapsed;
        MeetingRecordingRow.Visibility =
            state.Meeting == AppState.MeetingPhaseKind.Recording ? Visibility.Visible : Visibility.Collapsed;
        MeetingProcessingRow.Visibility =
            state.Meeting == AppState.MeetingPhaseKind.Processing ? Visibility.Visible : Visibility.Collapsed;

        MeetingErrorText.Text = state.MeetingError ?? "";
        MeetingErrorText.Visibility =
            state.Meeting == AppState.MeetingPhaseKind.Failed && state.MeetingError is not null
                ? Visibility.Visible : Visibility.Collapsed;

        MeetingIdleHint.Text = ModelPaths.DiarizationPresent
            ? ""
            : "说话人分离模型未安装：运行 windows/scripts/setup_diarization.ps1";
        MeetingFileButton.IsEnabled = ModelPaths.DiarizationPresent;

        MeetingStageText.Text = $"会议处理：{state.MeetingStage}";
        MeetingProgressBar.Value = state.MeetingProgress;

        MeetingResultButton.Visibility = state.MeetingResultPath is not null
            ? Visibility.Visible : Visibility.Collapsed;

        if (state.Meeting == AppState.MeetingPhaseKind.Recording)
            _meetingClock.Start();
        else
            _meetingClock.Stop();
        RefreshMeetingClock();
    }

    private void RefreshMeetingClock()
    {
        if (_deps.State.MeetingStartedAt is DateTime started)
            MeetingTimer.Text = DateTime.Now.Subtract(started).ToString(@"hh\:mm\:ss");
        else
            MeetingTimer.Text = "";
    }

    // ----- 文件转写区 -----

    private void RefreshFileJob()
    {
        AppState state = _deps.State;
        FileDropArea.Visibility = state.FileJob == AppState.FileJobKind.Idle
            ? Visibility.Visible : Visibility.Collapsed;
        FileRunningRow.Visibility = state.FileJob == AppState.FileJobKind.Running
            ? Visibility.Visible : Visibility.Collapsed;
        FileDoneRow.Visibility = state.FileJob == AppState.FileJobKind.Done
            ? Visibility.Visible : Visibility.Collapsed;
        FileErrorText.Text = state.FileJob == AppState.FileJobKind.Failed
            ? $"⚠ {state.FileJobText}" : "";
        FileErrorText.Visibility = state.FileJob == AppState.FileJobKind.Failed
            ? Visibility.Visible : Visibility.Collapsed;
        if (state.FileJob == AppState.FileJobKind.Running)
        {
            FileProgressText.Text = $"文件转写中… {(int)(state.FileJobProgress * 100)}%";
            FileProgressBar.Value = state.FileJobProgress;
        }
        if (state.FileJob == AppState.FileJobKind.Done)
            FileDoneText.Text = state.FileJobText ?? "";
    }

    // ----- 历史 -----

    private void RefreshHistory()
    {
        var records = _deps.History.Recent(20);
        HistoryList.ItemsSource = records;
        HistoryEmpty.Visibility = records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ----- 事件 -----

    private void OnRecordClicked(object sender, RoutedEventArgs e) => _deps.Dictation.Toggle();

    private void OnMeetingStartClicked(object sender, RoutedEventArgs e) =>
        _deps.Meeting.StartRecording();

    private void OnMeetingStopClicked(object sender, RoutedEventArgs e) =>
        _deps.Meeting.StopAndProcess();

    private void OnMeetingResultClicked(object sender, RoutedEventArgs e)
    {
        string? path = _deps.State.MeetingResultPath;
        if (path is not null)
            MeetingResultWindow.ShowResult(path);
    }

    private void OnFileDrop(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop))
            return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files)
            _deps.Dictation.TranscribeFile(files[0]);
    }

    private void OnPickFileClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择音频文件",
            Filter = "音频文件|*.wav;*.mp3;*.m4a;*.aac;*.wma;*.flac|所有文件|*.*",
        };
        if (dialog.ShowDialog(this) == true)
            _deps.Dictation.TranscribeFile(dialog.FileName);
    }

    private void OnPickMeetingFileClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择会议音频",
            Filter = "音频文件|*.wav;*.mp3;*.m4a;*.aac;*.wma;*.flac|所有文件|*.*",
        };
        if (dialog.ShowDialog(this) == true)
            _deps.Meeting.Process(dialog.FileName);
    }

    private void OnCopyFileResult(object sender, RoutedEventArgs e)
    {
        if (_deps.State.FileJobText is string text)
            TrySetClipboard(text);
    }

    private void OnFileDoneClose(object sender, RoutedEventArgs e)
    {
        _deps.State.FileJob = AppState.FileJobKind.Idle;
        _deps.State.FileJobText = null;
    }

    private void OnCopyRecord(object sender, RoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is TranscriptRecord record)
            TrySetClipboard(record.Text);
    }

    private void OnCopyRawContext(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is TranscriptRecord { RawText: not null } record)
            TrySetClipboard(record.RawText!);
    }

    private void OnDeleteContext(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.CommandParameter is TranscriptRecord record)
        {
            _deps.History.Delete(record.Id);
            RefreshHistory();
        }
    }

    private void OnClearHistory(object sender, RoutedEventArgs e)
    {
        _deps.History.Clear();
        RefreshHistory();
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e) => SettingsWindow.ShowSettings();

    private void OnExit(object sender, RoutedEventArgs e) => App.Current.ExitApp();

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        // 关面板不退出应用（托盘常驻）
        e.Cancel = true;
        Hide();
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
