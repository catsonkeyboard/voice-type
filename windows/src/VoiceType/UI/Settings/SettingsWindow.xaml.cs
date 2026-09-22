using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using VoiceType.Core;
using VoiceType.Models;
using VoiceType.Services;

namespace VoiceType.UI;

/// <summary>设置窗口（对应 macOS SettingsView 四个 Tab）。</summary>
public partial class SettingsWindow : Window
{
    private static SettingsWindow? _instance;

    public static void ShowSettings()
    {
        if (_instance is null)
            _instance = new SettingsWindow();
        _instance.Show();
        _instance.Activate();
    }

    private sealed record ModelRow(string Name, string Status, Brush Color, string Note, LocalAsrModel Value);

    private static readonly Brush OkBrush = new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50));
    private static readonly Brush WarnBrush = new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22));

    private readonly AppDependencies _deps = AppDependencies.Shared;
    private bool _loading = true;

    private SettingsWindow()
    {
        InitializeComponent();
        Load();
        _loading = false;
        Closed += (_, _) => _instance = null;
    }

    private void Load()
    {
        SettingsStore s = _deps.Settings;

        // 通用
        HotkeyRecorder.Combo = s.KeyCombo;
        LaunchAtLoginCheck.IsChecked = LaunchAtLogin.IsEnabled();

        // 识别
        EngineLocalRadio.IsChecked = s.AsrEngine == AsrEngine.Local;
        EngineDashRadio.IsChecked = s.AsrEngine == AsrEngine.DashScope;
        LocalModelCombo.ItemsSource = Enum.GetValues<LocalAsrModel>()
            .Select(m => new ModelRow(m.Label(), "", OkBrush, m.Note(), m))
            .ToList();
        LocalModelCombo.SelectedValue = s.LocalAsrModel;
        // Load 期间 SelectionChanged 被抑制，说明文本需手动补
        LocalModelNote.Text = s.LocalAsrModel.Note();
        DashKeyBox.Password = s.DashScopeApiKey;
        DashModelBox.Text = s.DashScopeModel;

        // 润色
        PolishEnabledCheck.IsChecked = s.PolishEnabled;
        PolishStyleCombo.ItemsSource = Enum.GetValues<PolishStyle>()
            .Select(x => x.Label())
            .ToList();
        PolishStyleCombo.SelectedIndex = (int)s.PolishStyle;
        PolishUrlBox.Text = s.PolishBaseUrl;
        PolishKeyBox.Password = s.PolishApiKey;
        PolishModelBox.Text = s.PolishModel;
        PresetCombo.ItemsSource = Enum.GetValues<PolishPreset>()
            .Select(p => $"{p.Label()}（{p.RecommendedModel()}）")
            .ToList();
        PresetCombo.SelectedIndex = -1;

        // 热词
        HotwordsBox.Text = s.HotwordsText;

        RefreshEngineSections();
        RefreshModelStatus();
        RefreshHotwordsCount();
    }

    // ----- 通用 -----

    private void OnHotkeyChanged(KeyCombo combo)
    {
        if (_loading)
            return;
        _deps.Settings.KeyCombo = combo;
        if (!Services.HotkeyManager.Shared.Register(combo))
            MessageBox.Show(this, $"快捷键 {combo.Display} 注册失败（可能被其他程序占用），已保留原设置。",
                "VoiceType", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private void OnLaunchAtLoginChanged(object sender, RoutedEventArgs e)
    {
        if (_loading)
            return;
        try
        {
            LaunchAtLogin.SetEnabled(LaunchAtLoginCheck.IsChecked == true);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"设置开机启动失败：{ex.Message}", "VoiceType",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            LaunchAtLoginCheck.IsChecked = LaunchAtLogin.IsEnabled();
        }
    }

    private void OnOpenModelsDir(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(ModelPaths.ModelsDir);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = ModelPaths.ModelsDir,
            UseShellExecute = true,
        });
    }

    private void OnRefreshModels(object sender, RoutedEventArgs e)
    {
        _deps.State.RefreshModelsReady();
        RefreshModelStatus();
    }

    // ----- 识别 -----

    private void OnEngineChanged(object sender, RoutedEventArgs e)
    {
        if (_loading)
            return;
        _deps.Settings.AsrEngine = EngineDashRadio.IsChecked == true
            ? AsrEngine.DashScope
            : AsrEngine.Local;
        RefreshEngineSections();
    }

    private void RefreshEngineSections()
    {
        bool cloud = EngineDashRadio.IsChecked == true;
        EngineCloudHint.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
        LocalModelSection.Visibility = cloud ? Visibility.Collapsed : Visibility.Visible;
        DashSection.Visibility = cloud ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnLocalModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || LocalModelCombo.SelectedValue is not LocalAsrModel model)
            return;
        _deps.Settings.LocalAsrModel = model;
        LocalModelNote.Text = model.Note();
        InstallCommandText.Text = $"未安装：{model.InstallCommand()}";
        _ = _deps.Asr.ReloadAsync();
        _deps.State.RefreshModelsReady();
        RefreshModelStatus();
    }

    private void RefreshModelStatus()
    {
        string Status(bool ok) => ok ? "✓ 已安装" : "未安装";
        Brush Color(bool ok) => ok ? OkBrush : WarnBrush;

        ModelStatusList.ItemsSource = Enum.GetValues<LocalAsrModel>()
            .Select(m => new ModelRow(
                m.Label(), Status(ModelPaths.IsPresent(m)), Color(ModelPaths.IsPresent(m)),
                m.Note(), m))
            .ToList();
        LocalModelStatusList.ItemsSource = ModelStatusList.ItemsSource;

        bool diarizationOk = ModelPaths.DiarizationPresent;
        DiarizationStatus.Text = $"分离模型：{Status(diarizationOk)}";
        DiarizationStatus.Foreground = Color(diarizationOk);
        DiarizationInstallHint.Visibility = diarizationOk
            ? Visibility.Collapsed : Visibility.Visible;
        DiarizationInstallHint.Text = @".\scripts\setup_diarization.ps1";

        LocalAsrModel current = _deps.Settings.LocalAsrModel;
        InstallCommandText.Text = ModelPaths.IsPresent(current)
            ? ""
            : $"未安装：{current.InstallCommand()}";
        InstallCommandText.Visibility = ModelPaths.IsPresent(current)
            ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnDashKeyChanged(object sender, RoutedEventArgs e)
    {
        if (!_loading)
            _deps.Settings.DashScopeApiKey = DashKeyBox.Password;
    }

    private void OnDashModelChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading)
            _deps.Settings.DashScopeModel = DashModelBox.Text;
    }

    private async void OnDashTest(object sender, RoutedEventArgs e)
    {
        if (DashKeyBox.Password.Length == 0)
            return;
        DashTestButton.IsEnabled = false;
        DashTestResult.Text = "测试中…";
        DashTestResult.Foreground = Brushes.Gray;
        var session = new DashScopeAsrSession(DashKeyBox.Password, DashModelBox.Text);
        try
        {
            await session.StartAsync();
            session.Send(new float[8000]);  // 0.5s 静音走完整协议
            _ = await session.FinishAsync();
            DashTestResult.Text = "连接成功，Key 有效";
            DashTestResult.Foreground = OkBrush;
        }
        catch (Exception ex)
        {
            session.Cancel();
            DashTestResult.Text = $"失败：{ex.Message}";
            DashTestResult.Foreground = new SolidColorBrush(Color.FromRgb(0xE5, 0x48, 0x4D));
        }
        finally
        {
            session.Dispose();
            DashTestButton.IsEnabled = true;
        }
    }

    // ----- 润色 -----

    private void OnPolishEnabledChanged(object sender, RoutedEventArgs e)
    {
        if (_loading)
            return;
        _deps.Settings.PolishEnabled = PolishEnabledCheck.IsChecked == true;
        if (PolishEnabledCheck.IsChecked == true)
            _deps.Polish.WarmUp();
    }

    private void OnPolishStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && PolishStyleCombo.SelectedIndex >= 0)
            _deps.Settings.PolishStyle = (PolishStyle)PolishStyleCombo.SelectedIndex;
    }

    private void OnPresetSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || PresetCombo.SelectedIndex < 0)
            return;
        var preset = (PolishPreset)PresetCombo.SelectedIndex;
        PolishUrlBox.Text = preset.BaseUrl();
        PolishModelBox.Text = preset.RecommendedModel();
        // TextChanged 已写回设置
        PresetCombo.SelectedIndex = -1;
    }

    private void OnPolishUrlChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading)
            _deps.Settings.PolishBaseUrl = PolishUrlBox.Text;
    }

    private void OnPolishKeyChanged(object sender, RoutedEventArgs e)
    {
        if (!_loading)
            _deps.Settings.PolishApiKey = PolishKeyBox.Password;
    }

    private void OnPolishModelChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading)
            _deps.Settings.PolishModel = PolishModelBox.Text;
    }

    private async void OnProbePolish(object sender, RoutedEventArgs e)
    {
        ProbeButton.IsEnabled = false;
        ProbeResult.Text = "检测中…";
        PolishService.ProbeResult result = await _deps.Polish.Probe();
        ProbeButton.IsEnabled = true;
        if (!result.Reachable)
        {
            ProbeResult.Foreground = new SolidColorBrush(Color.FromRgb(0xE5, 0x48, 0x4D));
            ProbeResult.Text = $"无法连接：{result.ErrorMessage ?? "未知错误"}（Ollama 是否在运行？）";
            return;
        }
        ProbeResult.Foreground = OkBrush;
        if (result.Models.Count == 0)
        {
            ProbeResult.Text = "已连接（该服务不支持列出模型）";
        }
        else if (result.Models.Contains(PolishModelBox.Text))
        {
            ProbeResult.Text = "已连接，模型可用";
        }
        else
        {
            ProbeResult.Foreground = WarnBrush;
            ProbeResult.Text = $"已连接，但模型未安装：ollama pull {PolishModelBox.Text}";
        }
    }

    // ----- 热词 -----

    private void OnHotwordsChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading)
            return;
        _deps.Settings.HotwordsText = HotwordsBox.Text;
        RefreshHotwordsCount();
    }

    private void RefreshHotwordsCount() =>
        HotwordsCount.Text = $"当前生效 {_deps.Settings.Hotwords.Count} 个热词";
}
