using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using H.NotifyIcon;
using VoiceType.Core;
using VoiceType.UI;
using VoiceType.UI.Panel;

namespace VoiceType;

public partial class App : Application
{
    private Mutex? _singleInstanceMutex;
    private TaskbarIcon? _tray;
    private AppDependencies _deps = null!;

    public new static App Current => (App)Application.Current;

    public AppDependencies Deps => _deps;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(true, "VoiceTypeWinSingleInstance", out bool isNew);
        if (!isNew)
        {
            MessageBox.Show("VoiceType 已在运行（请查看系统托盘）。", "VoiceType",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        _deps = AppDependencies.Shared;
        CreateTray();
        PanelWindow.ShowPanel();
    }

    private void CreateTray()
    {
        _tray = new TaskbarIcon
        {
            ToolTipText = "VoiceType",
            IconSource = LoadIcon("app.ico"),
        };
        var menu = new System.Windows.Controls.ContextMenu();

        var panelItem = new System.Windows.Controls.MenuItem { Header = "面板(_P)" };
        panelItem.Click += (_, _) => PanelWindow.ShowPanel();
        var settingsItem = new System.Windows.Controls.MenuItem { Header = "设置(_S)…" };
        settingsItem.Click += (_, _) => SettingsWindow.ShowSettings();
        var dictationItem = new System.Windows.Controls.MenuItem
        {
            Header = "开始听写(_D)",
        };
        dictationItem.Click += (_, _) => _deps.Dictation.Toggle();
        var exitItem = new System.Windows.Controls.MenuItem { Header = "退出(_X)" };
        exitItem.Click += (_, _) => ExitApp();

        menu.Items.Add(panelItem);
        menu.Items.Add(settingsItem);
        menu.Items.Add(dictationItem);
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(exitItem);
        _tray.ContextMenu = menu;

        _tray.TrayLeftMouseUp += (_, _) => PanelWindow.ShowPanel();

        // 图标随阶段切换：录音时红点
        _deps.State.PropertyChanged += (s, e) =>
        {
            if (e.PropertyName == nameof(AppState.Phase))
            {
                Dispatcher.Invoke(() =>
                {
                    _tray.IconSource = LoadIcon(
                        _deps.State.Phase == AppState.PhaseKind.Recording
                            ? "app-rec.ico"
                            : "app.ico");
                    dictationItem.Header = _deps.State.Phase == AppState.PhaseKind.Recording
                        ? "停止听写(_D)"
                        : "开始听写(_D)";
                });
            }
        };
    }

    private static ImageSource? LoadIcon(string name)
    {
        try
        {
            string path = Path.Combine(AppContext.BaseDirectory, "Assets", name);
            return File.Exists(path)
                ? System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(path))
                : null;
        }
        catch
        {
            return null;
        }
    }

    public void ExitApp()
    {
        _tray?.Dispose();
        Services.HotkeyManager.Shared.Dispose();
        _deps.Meeting.Dispose();
        _deps.Asr.Dispose();
        Shutdown();
        Environment.Exit(0);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _singleInstanceMutex?.ReleaseMutex();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
