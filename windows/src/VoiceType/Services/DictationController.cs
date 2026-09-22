using System.Windows.Threading;
using VoiceType.Core;
using VoiceType.UI;

namespace VoiceType.Services;

/// <summary>
/// 听写编排：快捷键/面板触发 → 录音 → 识别 → 热词纠正 → 注入 → 历史。
/// 编排本身运行在 UI 线程（Swift @MainActor 对应物）；推理由 AsrService
/// 内部挪到线程池串行队列，UI 不阻塞；TextInjector 依赖 UI(STA) 线程。
/// </summary>
public sealed class DictationController
{
    public const double MaxRecordingSeconds = 300;
    public const double MinRecordingSeconds = 0.5;

    private readonly AppState _state;
    private readonly AsrService _asr;
    private readonly PolishService _polish;
    private readonly HistoryStore _history;
    private readonly SettingsStore _settings;
    private readonly AudioRecorder _recorder = new();
    private DispatcherTimer? _capTimer;
    private DashScopeAsrSession? _cloudSession;

    public DictationController(
        AppState state, AsrService asr, HistoryStore history, PolishService polish,
        SettingsStore? settings = null)
    {
        _state = state;
        _asr = asr;
        _history = history;
        _polish = polish;
        _settings = settings ?? SettingsStore.Default;
    }

    /// <summary>快捷键与面板按钮共用的入口：idle→开始，recording→结束</summary>
    public void Toggle()
    {
        if (_state.Meeting == AppState.MeetingPhaseKind.Recording)
        {
            HudController.Shared.Flash("会议录音进行中，听写不可用", _state);
            return;
        }
        switch (_state.Phase)
        {
            case AppState.PhaseKind.Idle:
            case AppState.PhaseKind.Error:
                StartRecording();
                break;
            case AppState.PhaseKind.Recording:
                _ = FinishRecordingAsync();
                break;
            case AppState.PhaseKind.Transcribing:
            case AppState.PhaseKind.Polishing:
                break;  // 识别/润色中忽略触发
        }
    }

    private void StartRecording()
    {
        AsrEngine engine = _settings.AsrEngine;
        switch (engine)
        {
            case AsrEngine.Local:
                _state.RefreshModelsReady();
                if (!_state.ModelsReady)
                {
                    _state.SetPhaseError($"本地识别模型未安装（{_settings.LocalAsrModel.Label()}）");
                    HudController.Shared.Flash("模型未安装，请查看设置", _state);
                    return;
                }
                break;
            case AsrEngine.DashScope:
                if (_settings.DashScopeApiKey.Length == 0)
                {
                    _state.SetPhaseError("未配置 DashScope API Key");
                    HudController.Shared.Flash("请在设置 → 识别 中填写 DashScope API Key", _state);
                    return;
                }
                break;
        }

        if (engine == AsrEngine.DashScope)
            SetupCloudSession();
        _recorder.OnLevel = level => _state.MicLevel = level;
        _recorder.OnChunk = chunk => _cloudSession?.Send(chunk);
        try
        {
            _recorder.Start();
        }
        catch (RecorderException e)
        {
            _cloudSession?.Cancel();
            _cloudSession = null;
            _state.SetPhaseError(e.Message);
            HudController.Shared.Flash(e.Message, _state);
            return;
        }
        _state.Phase = AppState.PhaseKind.Recording;
        HudController.Shared.Show(_state);
        _capTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(MaxRecordingSeconds),
        };
        _capTimer.Tick += (_, _) => _ = FinishRecordingAsync();
        _capTimer.Start();
    }

    /// <summary>并行建立云端会话；建连失败仅使本次云端不可用（finish 时走本地回退）</summary>
    private void SetupCloudSession()
    {
        var session = new DashScopeAsrSession(
            _settings.DashScopeApiKey, _settings.DashScopeModel);
        session.OnPartial = text => _state.PartialText = text;
        _cloudSession = session;
        _ = Task.Run(async () =>
        {
            try
            {
                await session.StartAsync();
            }
            catch
            {
                await App.Current.Dispatcher.InvokeAsync(() =>
                {
                    // 仅当仍是当前会话时清除（避免竞态清掉下一次的会话）
                    if (ReferenceEquals(_cloudSession, session))
                        _cloudSession = null;
                });
            }
        });
    }

    private async Task FinishRecordingAsync()
    {
        if (_state.Phase != AppState.PhaseKind.Recording)
            return;
        _capTimer?.Stop();
        _capTimer = null;
        float[] samples = _recorder.Stop();
        _recorder.OnChunk = null;
        DashScopeAsrSession? session = _cloudSession;
        _cloudSession = null;
        _state.PartialText = null;

        double duration = samples.Length / 16000.0;
        if (duration < MinRecordingSeconds)
        {
            session?.Cancel();
            _state.Phase = AppState.PhaseKind.Idle;
            HudController.Shared.Hide();
            return;
        }
        DebugAudioDump.Write(samples);
        _state.Phase = AppState.PhaseKind.Transcribing;
        try
        {
            bool cloudDegraded = false;
            string text;
            if (session is not null)
            {
                try
                {
                    text = await session.FinishAsync();
                }
                catch
                {
                    session.Cancel();
                    cloudDegraded = true;
                    text = await _asr.TranscribeAsync(samples);
                }
            }
            else
            {
                if (_settings.AsrEngine == AsrEngine.DashScope)
                    cloudDegraded = true;
                text = await _asr.TranscribeAsync(samples);
            }
            text = new HotwordCorrector(_settings.Hotwords).Correct(text);
            if (text.Length == 0)
            {
                _state.Phase = AppState.PhaseKind.Idle;
                HudController.Shared.Hide();
                return;
            }
            string? rawText = null;
            bool polishDegraded = false;
            if (_settings.PolishEnabled && text.Length >= 5)
            {
                _state.Phase = AppState.PhaseKind.Polishing;
                string? polished = await _polish.Polish(text);
                if (polished is not null)
                {
                    if (polished != text)
                        rawText = text;
                    text = polished;
                }
                else
                {
                    polishDegraded = true;
                }
            }
            _history.Add(text, duration, "dictation", rawText);
            InjectResult result = TextInjector.Inject(text);
            _state.Phase = AppState.PhaseKind.Idle;
            switch (result)
            {
                case InjectResult.Injected:
                    if (cloudDegraded)
                        HudController.Shared.Flash("云端不可用，已用本地识别", _state);
                    else if (polishDegraded)
                        HudController.Shared.Flash("润色不可用，已输出原文", _state);
                    else
                        HudController.Shared.Hide();
                    break;
                case InjectResult.CopiedToClipboard:
                    HudController.Shared.Flash("已复制到剪贴板，请按 Ctrl+V 粘贴", _state);
                    break;
            }
        }
        catch (Exception e)
        {
            _state.SetPhaseError(e.Message);
            HudController.Shared.Flash($"识别失败：{e.Message}", _state);
        }
    }

    /// <summary>面板文件转写入口</summary>
    public void TranscribeFile(string path)
    {
        if (_state.FileJob == AppState.FileJobKind.Running)
            return;
        _state.RefreshModelsReady();
        if (!_state.ModelsReady)
        {
            _state.SetFileJobFailed($"本地识别模型未安装（{_settings.LocalAsrModel.Label()}）");
            return;
        }
        _state.FileJob = AppState.FileJobKind.Running;
        _state.FileJobProgress = 0;
        _ = TranscribeFileAsync(path);
    }

    private async Task TranscribeFileAsync(string path)
    {
        try
        {
            string text = await _asr.TranscribeFileAsync(path, p =>
            {
                _ = App.Current.Dispatcher.InvokeAsync(() =>
                {
                    _state.FileJob = AppState.FileJobKind.Running;
                    _state.FileJobProgress = p;
                });
            });
            if (text.Length == 0)
            {
                _state.SetFileJobFailed("未识别到语音内容");
            }
            else
            {
                string corrected = new HotwordCorrector(_settings.Hotwords).Correct(text);
                _history.Add(corrected, 0, "file");
                _state.FileJob = AppState.FileJobKind.Done;
                _state.FileJobText = corrected;
            }
        }
        catch (Exception e)
        {
            _state.SetFileJobFailed(e.Message);
        }
    }
}
