using System.Diagnostics;
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
    /// <summary>边录边跟踪人声，用来自动结束（见 SpeechGate.Watch）</summary>
    private SpeechGate.Tracker _speechTracker = new();
    /// <summary>已经因为没有人声或安静太久而要求结束，避免重复触发</summary>
    private bool _autoEnding;
    /// <summary>当前这次听写的去向；结束或取消时复位为 Cursor</summary>
    private DictationTarget _target = DictationTarget.Cursor;
    /// <summary>录音已结束、还在识别没回传的第三方会话</summary>
    private string? _transcribingSession;
    /// <summary>识别期间被第三方应用取消的会话：识别完不回传</summary>
    private string? _droppedSession;

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
                StartRecording(DictationTarget.Cursor);
                break;
            case AppState.PhaseKind.Recording:
                _ = FinishRecordingAsync();
                break;
            case AppState.PhaseKind.Transcribing:
            case AppState.PhaseKind.Polishing:
                break;  // 识别/润色中忽略触发
        }
    }

    /// <summary>第三方应用通过 voicetype:// 发来的请求（v6）。必须在 UI 线程调用。</summary>
    public void Handle(BridgeRequest request)
    {
        // Windows 录音启动是同步的、授权弹窗会阻塞 UI 线程：请求只会排队依次处理，
        // 不存在 macOS 那样的「启动中/弹窗中」并发窗口，idle 只看当前状态
        bool idle = _state.Phase is AppState.PhaseKind.Idle or AppState.PhaseKind.Error;
        bool meetingRecording = _state.Meeting == AppState.MeetingPhaseKind.Recording;
        BridgePermission permission = request.CallbackUrl is { } callback
            ? _settings.BridgePermissionFor(callback)
            : BridgePermission.Unknown;
        BridgeAction action = request.Action(
            idle, recording: _state.Phase == AppState.PhaseKind.Recording, meetingRecording,
            _target, permission, _transcribingSession);
        switch (action)
        {
            case BridgeAction.Start start:
                StartRecording(new DictationTarget.External(start.Session, start.Callback));
                break;
            case BridgeAction.AskPermission ask:
            {
                // 这是联动里唯一会抢焦点的地方：每个回调地址只弹一次
                bool? allowed = BridgePermissionPrompt.Ask(ask.Callback);
                if (allowed is null)
                {
                    // 没有应用能接收这个回调：结果无处可送，不录音
                    Debug.WriteLine("VoiceType: 回调地址没有对应的应用，忽略请求");
                    return;
                }
                _settings.SetBridgePermission(allowed.Value, ask.Callback);
                // 记下选择后重新判定：允许→开始；拒绝→not_allowed
                Handle(request);
                break;
            }
            case BridgeAction.FinishCase:
                _ = FinishRecordingAsync();
                break;
            case BridgeAction.CancelCase:
                CancelRecording();
                break;
            case BridgeAction.DropReplyCase:
                _droppedSession = _transcribingSession;
                break;
            case BridgeAction.Refuse refuse:
                BridgeTransport.Send(
                    refuse.Callback, refuse.Session,
                    new BridgeOutcome.WithFailure(refuse.Reason));
                break;
        }
    }

    private void StartRecording(DictationTarget target)
    {
        _target = target;
        AsrEngine engine = _settings.AsrEngine;
        switch (engine)
        {
            case AsrEngine.Local:
                _state.RefreshModelsReady();
                if (!_state.ModelsReady)
                {
                    _state.SetPhaseError($"本地识别模型未安装（{_settings.LocalAsrModel.Label()}）");
                    HudController.Shared.Flash("模型未安装，请查看设置", _state);
                    FailStart(BridgeFailure.NotReady);
                    return;
                }
                break;
            case AsrEngine.DashScope:
                if (_settings.DashScopeApiKey.Length == 0)
                {
                    _state.SetPhaseError("未配置 DashScope API Key");
                    HudController.Shared.Flash("请在设置 → 识别 中填写 DashScope API Key", _state);
                    FailStart(BridgeFailure.NotReady);
                    return;
                }
                break;
        }

        if (engine == AsrEngine.DashScope)
            SetupCloudSession();
        _recorder.OnLevel = level => _state.MicLevel = level;
        _speechTracker = new SpeechGate.Tracker();
        _autoEnding = false;
        _recorder.OnChunk = chunk =>
        {
            _cloudSession?.Send(chunk);
            WatchSpeech(chunk);
        };
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
            FailStart(BridgeFailure.Failed);
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

    /// <summary>录音没能开始：若由第三方应用发起，把原因回传；去向复位</summary>
    private void FailStart(BridgeFailure reason)
    {
        Reply(_target, new BridgeOutcome.WithFailure(reason));
        _target = DictationTarget.Cursor;
    }

    /// <summary>只有第三方应用发起的听写才回传</summary>
    private void Reply(DictationTarget target, BridgeOutcome outcome)
    {
        if (target is not DictationTarget.External external)
            return;
        if (_transcribingSession == external.Session)
            _transcribingSession = null;
        if (_droppedSession == external.Session)
        {
            // 第三方应用在结果回来之前退出了：回传会把它重新拉起来
            _droppedSession = null;
            Debug.WriteLine("VoiceType: 第三方应用已取消这次听写，结果不回传");
            return;
        }
        BridgeTransport.Send(external.Callback, external.Session, outcome);
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
        // 去向在这里取走：识别期间开始的下一次听写不受影响
        DictationTarget target = _target;
        _target = DictationTarget.Cursor;
        // 识别期间第三方应用还可能取消这次会话（它要退出了），见 BridgeAction.DropReply
        if (target is DictationTarget.External external)
        {
            _transcribingSession = external.Session;
            _droppedSession = null;
        }
        float[] samples = _recorder.Stop();
        _recorder.OnChunk = null;
        DashScopeAsrSession? session = _cloudSession;
        _cloudSession = null;
        _state.PartialText = null;

        double duration = samples.Length / 16000.0;
        // 先留调试录音：被下面挡掉的也留一份，方便核对人声门槛
        DebugAudioDump.Write(samples);
        // 录了 0.5 秒以上却全是绝对的 0：麦克风被系统拦下了，按没有授权处理，不是没说话
        if (duration >= MinRecordingSeconds && SpeechGate.IsDigitalSilence(samples))
        {
            Debug.WriteLine("VoiceType: 录音全是静音数据，麦克风可能没有授权");
            session?.Cancel();
            _state.SetPhaseError("麦克风没有收到声音");
            HudController.Shared.Flash(
                "麦克风没有收到声音，请在系统设置中允许 VoiceType 使用麦克风", _state);
            Reply(target, new BridgeOutcome.WithFailure(BridgeFailure.MicDenied));
            return;
        }
        SpeechGate.Analysis speech = SpeechGate.Analyze(samples);
        // 太短，或只录到按键声、底噪：不送去识别，否则模型会幻听出文字（见 SpeechGate）
        if (duration < MinRecordingSeconds || !speech.HasSpeech)
        {
            if (duration >= MinRecordingSeconds)
            {
                // 只记数字，不含录音内容
                Debug.WriteLine(
                    $"VoiceType: 没有检测到人声（最长连续 {speech.LongestRunSeconds:F2} 秒，" +
                    $"最大音量 {speech.PeakLevel:F3}），按没说话处理");
            }
            session?.Cancel();
            _state.Phase = AppState.PhaseKind.Idle;
            HudController.Shared.Hide();
            Reply(target, new BridgeOutcome.WithFailure(BridgeFailure.Empty));
            return;
        }
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
            // 去掉模型漏出来的静音标记（/sil 等），只剩它们时按没说话处理；
            // 模型卡在循环里反复输出的片段只留一份（见 RepetitionGuard）
            text = RepetitionGuard.Collapse(SpeechGate.StripSilenceTokens(text));
            text = new HotwordCorrector(DevGlossary.MergedWithUser(_settings.Hotwords)).Correct(text);
            if (text.Length == 0)
            {
                _state.Phase = AppState.PhaseKind.Idle;
                HudController.Shared.Hide();
                Reply(target, new BridgeOutcome.WithFailure(BridgeFailure.Empty));
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
                    // 润色模型同样可能陷入循环
                    string cleaned = RepetitionGuard.Collapse(polished);
                    if (cleaned != text)
                        rawText = text;
                    text = cleaned;
                }
                else
                {
                    polishDegraded = true;
                }
            }
            _history.Add(text, duration,
                target == DictationTarget.Cursor ? "dictation" : "external", rawText);
            // （Windows 版云端会话无断线追踪，cloudDegraded 只在建连/收尾失败时置位）
            string? degraded = cloudDegraded
                ? "云端不可用，已用本地识别"
                : polishDegraded ? "润色不可用，已输出原文" : null;
            if (target is DictationTarget.External)
            {
                // 第三方应用发起：回传文字，不写剪贴板、不模拟 Ctrl+V
                _state.Phase = AppState.PhaseKind.Idle;
                Reply(target, new BridgeOutcome.WithText(text));
                ShowDegraded(degraded);
                return;
            }
            InjectResult result = TextInjector.Inject(text);
            _state.Phase = AppState.PhaseKind.Idle;
            switch (result)
            {
                case InjectResult.Injected:
                    ShowDegraded(degraded);
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
            Reply(target, new BridgeOutcome.WithFailure(BridgeFailure.Failed));
        }
    }

    /// <summary>降级提示显示一下；没有降级就收起 HUD</summary>
    private void ShowDegraded(string? message)
    {
        if (message is not null)
            HudController.Shared.Flash(message, _state);
        else
            HudController.Shared.Hide();
    }

    /// <summary>丢弃当前录音：不识别、不回传（第三方应用取消了这次说话）</summary>
    private void CancelRecording()
    {
        _capTimer?.Stop();
        _capTimer = null;
        if (_state.Phase != AppState.PhaseKind.Recording)
            return;
        _ = _recorder.Stop();
        _recorder.OnChunk = null;
        _cloudSession?.Cancel();
        _cloudSession = null;
        _state.PartialText = null;
        _target = DictationTarget.Cursor;
        _transcribingSession = null;
        _droppedSession = null;
        _state.Phase = AppState.PhaseKind.Idle;
        HudController.Shared.Hide();
    }

    /// <summary>
    /// 边录边看有没有人声：开头一直没人说话，或说完后安静很久，就像再按一次快捷键那样结束。
    /// 没人说话的录音会在结束时被 SpeechGate 判成「没说话」。
    /// OnChunk 由录音器派发到 UI 线程回调，这里可以直接结束录音。
    /// </summary>
    private void WatchSpeech(float[] chunk)
    {
        if (_state.Phase != AppState.PhaseKind.Recording || _autoEnding)
            return;
        _speechTracker.Feed(chunk);
        SpeechGate.WatchResult verdict = SpeechGate.Watch(_speechTracker);
        if (verdict == SpeechGate.WatchResult.KeepGoing)
            return;
        _autoEnding = true;
        if (verdict == SpeechGate.WatchResult.NoSpeech)
            Debug.WriteLine($"VoiceType: 开头 {SpeechGate.NoSpeechTimeoutSeconds:F0} 秒没有人声，自动结束录音");
        else
            Debug.WriteLine($"VoiceType: 说完后安静了 {SpeechGate.TrailingSilenceSeconds:F0} 秒，自动结束录音");
        _ = FinishRecordingAsync();
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
                string corrected = new HotwordCorrector(DevGlossary.MergedWithUser(_settings.Hotwords)).Correct(text);
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
