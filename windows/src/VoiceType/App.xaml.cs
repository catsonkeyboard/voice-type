using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Windows;
using System.Windows.Media;
using H.NotifyIcon;
using VoiceType.Core;
using VoiceType.Services;
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
        DiagnosticsLog.Write($"startup begin, args={e.Args.Length}");
        DispatcherUnhandledException += (_, ex) =>
            DiagnosticsLog.Write("dispatcher unhandled", ex.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
            DiagnosticsLog.Write($"domain unhandled: {ex.ExceptionObject}");

        // 第三方应用联动（v6）：注册 voicetype://，使 shell 能用 URL 拉起/唤起本应用
        BridgeTransport.RegisterScheme();
        string? bridgeUrl = e.Args.FirstOrDefault(
            a => a.StartsWith($"{BridgeTransport.Scheme}://", StringComparison.OrdinalIgnoreCase));

        _singleInstanceMutex = new Mutex(true, "VoiceTypeWinSingleInstance", out bool isNew);
        if (!isNew)
        {
            if (bridgeUrl is not null)
            {
                // 已在运行：把 URL 静默转发给第一个实例，不弹框（对应 macOS 的 GetURL 事件）
                ForwardToRunningInstance(bridgeUrl);
            }
            else
            {
                MessageBox.Show("VoiceType 已在运行（请查看系统托盘）。", "VoiceType",
                    MessageBoxButton.OK, MessageBoxImage.Information);
            }
            Shutdown();
            return;
        }

        _deps = AppDependencies.Shared;
        DiagnosticsLog.Write("deps ready");
        CreateTray();
        PanelWindow.ShowPanel();
        StartBridgePipeServer();
        // 冷启动：应用本来就是被这个 URL 拉起的，依赖就绪后立刻处理
        if (bridgeUrl is not null)
            HandleBridgeUrl(bridgeUrl);
        DiagnosticsLog.Write("startup done");
    }

    /// <summary>第二个实例把 voicetype:// URL 发给已在运行的实例（1.5s 等不到就放弃，不报错）</summary>
    private static void ForwardToRunningInstance(string url)
    {
        try
        {
            using var client = new NamedPipeClientStream(
                ".", BridgeTransport.PipeName, PipeDirection.Out);
            client.Connect(1500);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.Write(url);
        }
        catch
        {
            // 对方没接上（旧版本在跑等）：静默放弃
        }
    }

    /// <summary>常驻接收第二实例转发来的 voicetype:// URL（仅当前用户可连）</summary>
    private void StartBridgePipeServer()
    {
        _ = Task.Run(async () =>
        {
            while (true)
            {
                NamedPipeServerStream server;
                try
                {
                    server = new NamedPipeServerStream(
                        BridgeTransport.PipeName, PipeDirection.In,
                        maxNumberOfServerInstances: 1,
                        transmissionMode: PipeTransmissionMode.Byte,
                        options: PipeOptions.CurrentUserOnly);
                }
                catch
                {
                    return;
                }
                using (server)
                {
                    try
                    {
                        await server.WaitForConnectionAsync();
                        using var reader = new StreamReader(server);
                        string? url = await reader.ReadToEndAsync();
                        if (!string.IsNullOrWhiteSpace(url))
                            await Dispatcher.InvokeAsync(() => HandleBridgeUrl(url.Trim()));
                    }
                    catch
                    {
                        // 单个连接出错不影响继续接收
                    }
                }
            }
        });
    }

    /// <summary>解析并分发一个 voicetype:// URL；只记日志行，不写 URL 的任何部分</summary>
    private void HandleBridgeUrl(string url)
    {
        try
        {
            BridgeRequest? request = BridgeRequest.Parse(url);
            if (request is null)
            {
                Debug.WriteLine("VoiceType: 忽略了一个无法识别的 voicetype:// 请求");
                return;
            }
            _deps.Dictation.Handle(request);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"VoiceType: 处理 voicetype:// 请求异常（{ex.GetType().Name}）");
        }
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
        try
        {
            // 纯代码创建的 TaskbarIcon 不在可视化树里，Loaded 永远不会触发，
            // 必须显式 ForceCreate 才会向系统注册托盘图标（H.NotifyIcon v2 的
            // windowless 官方用法；缺了这一步就是「进程活着但托盘无图标」）
            _tray.ForceCreate();
            DiagnosticsLog.Write("tray force-created");
        }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("tray ForceCreate failed", ex);
        }

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
