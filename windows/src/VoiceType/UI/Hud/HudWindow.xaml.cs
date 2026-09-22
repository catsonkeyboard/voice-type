using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Controls;
using System.Windows.Shapes;
using System.Windows.Threading;
using VoiceType.Core;

namespace VoiceType.UI;

/// <summary>
/// 录音/识别状态悬浮窗：无边框、不抢焦点、置顶、点击穿透
/// （对应 macOS NSPanel nonactivatingPanel + ignoresMouseEvents）。
/// </summary>
public partial class HudWindow : Window
{
    private const int WsExTransparent = 0x00000020;
    private const int WsExNoActivate = 0x08000000;
    private const int GwlExStyle = -20;

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);

    private const int BarCount = 8;
    private readonly Rectangle[] _bars = new Rectangle[BarCount];
    private readonly DispatcherTimer _decayTimer;
    private float _lastLevel;

    public HudWindow(AppState state)
    {
        InitializeComponent();
        DataContext = state;

        for (int i = 0; i < BarCount; i++)
        {
            var bar = new Rectangle
            {
                Width = 3,
                Height = 5 + i * 1.5,
                RadiusX = 1.5,
                RadiusY = 1.5,
                Fill = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0xB8, 0xB8, 0xB8)),
            };
            Canvas.SetLeft(bar, i * 7);
            Canvas.SetTop(bar, 16 - bar.Height);
            LevelBars.Children.Add(bar);
            _bars[i] = bar;
        }

        state.PropertyChanged += (_, e) => Dispatcher.Invoke(() =>
        {
            switch (e.PropertyName)
            {
                case nameof(AppState.MicLevel):
                    _lastLevel = state.MicLevel;
                    UpdateBars(_lastLevel);
                    break;
                case nameof(AppState.PartialText):
                    PartialText.Text = state.PartialText ?? "";
                    break;
                default:
                    RefreshRows(state);
                    break;
            }
        });

        // 电平自然衰减：录音停止后柱条归零
        _decayTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _decayTimer.Tick += (_, _) =>
        {
            _lastLevel *= 0.65f;
            UpdateBars(_lastLevel);
        };
        _decayTimer.Start();

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int ex = GetWindowLong(hwnd, GwlExStyle);
            SetWindowLong(hwnd, GwlExStyle, ex | WsExTransparent | WsExNoActivate);
            PositionTopCenter();
        };
        RefreshRows(state);
    }

    private void UpdateBars(float level)
    {
        for (int i = 0; i < BarCount; i++)
        {
            bool on = (float)i / BarCount < level;
            _bars[i].Fill = new System.Windows.Media.SolidColorBrush(on
                ? System.Windows.Media.Color.FromRgb(0xE5, 0x48, 0x4D)
                : System.Windows.Media.Color.FromRgb(0xB8, 0xB8, 0xB8));
        }
    }

    private void RefreshRows(AppState state)
    {
        MessageRow.Visibility =
            state.HudMessage is not null ? Visibility.Visible : Visibility.Collapsed;
        MessageText.Text = state.HudMessage ?? "";
        RecordingRow.Visibility =
            state.HudMessage is null && state.Phase == AppState.PhaseKind.Recording
                ? Visibility.Visible : Visibility.Collapsed;
        TranscribingRow.Visibility =
            state.HudMessage is null && state.Phase == AppState.PhaseKind.Transcribing
                ? Visibility.Visible : Visibility.Collapsed;
        PolishingRow.Visibility =
            state.HudMessage is null && state.Phase == AppState.PhaseKind.Polishing
                ? Visibility.Visible : Visibility.Collapsed;
        if (state.HudMessage is not null)
            PartialText.Text = "";
    }

    private void PositionTopCenter()
    {
        double screenWidth = SystemParameters.WorkArea.Width;
        Left = screenWidth / 2 - Width / 2;
        Top = SystemParameters.WorkArea.Top + 12;
    }
}

/// <summary>HUD 控制器单例（对应 macOS HUDController）。</summary>
public sealed class HudController
{
    public static readonly HudController Shared = new();

    private HudWindow? _window;
    private CancellationTokenSource? _flashCts;

    private HudController() { }

    public void Show(AppState state)
    {
        _flashCts?.Cancel();
        _window ??= CreateWindow(state);
        if (_window.Visibility != Visibility.Visible)
        {
            _window.Show();
        }
        _window.Dispatcher.Invoke(() => { });
    }

    private static HudWindow CreateWindow(AppState state)
    {
        var w = new HudWindow(state)
        {
            ShowInTaskbar = false,
        };
        w.ShowActivated = false;
        return w;
    }

    /// <summary>显示一条短消息后自动隐藏</summary>
    public async void Flash(string message, AppState state, double seconds = 2.0)
    {
        state.HudMessage = message;
        Show(state);
        _flashCts?.Cancel();
        _flashCts = new CancellationTokenSource();
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds), _flashCts.Token);
            state.HudMessage = null;
            Hide();
        }
        catch (TaskCanceledException)
        {
            // 新的 show/flash 打断了本次淡出
        }
    }

    public void Hide()
    {
        if (_window is null)
            return;
        if (_window.Dispatcher.CheckAccess())
            _window.Hide();
        else
            _window.Dispatcher.Invoke(_window.Hide);
    }
}
