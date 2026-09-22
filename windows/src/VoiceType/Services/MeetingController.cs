using VoiceType.Core;
using VoiceType.Models;
using VoiceType.UI;

namespace VoiceType.Services;

/// <summary>会议功能编排：录制生命周期 + 处理进度 + 结果路径（运行在 UI 线程）。</summary>
public sealed class MeetingController : IDisposable
{
    private readonly AppState _state;
    private readonly MeetingRecorder _recorder = new();
    private readonly MeetingProcessor _processor;

    public MeetingController(AppState state, AsrService asr)
    {
        _state = state;
        _processor = new MeetingProcessor(asr);
        _recorder.OnAutoStop = () => StopAndProcess();
    }

    public bool IsRecording => _state.Meeting == AppState.MeetingPhaseKind.Recording;

    public void StartRecording()
    {
        _state.RefreshModelsReady();
        if (!_state.ModelsReady)
        {
            _state.SetMeetingFailed(
                $"本地识别模型未安装（{SettingsStore.Default.LocalAsrModel.Label()}），请运行 "
                + SettingsStore.Default.LocalAsrModel.InstallCommand());
            return;
        }
        if (!ModelPaths.DiarizationPresent)
        {
            _state.SetMeetingFailed(
                "说话人分离模型未安装，请运行 windows/scripts/setup_diarization.ps1");
            return;
        }
        if (_state.Phase != AppState.PhaseKind.Idle)
        {
            _state.SetMeetingFailed("请先结束当前听写");
            return;
        }
        try
        {
            _ = _recorder.Start();
            _state.Meeting = AppState.MeetingPhaseKind.Recording;
            _state.MeetingStartedAt = DateTime.Now;
        }
        catch (RecorderException e)
        {
            _state.SetMeetingFailed(e.Message);
        }
    }

    public void StopAndProcess()
    {
        if (_state.Meeting != AppState.MeetingPhaseKind.Recording)
            return;
        string? path = _recorder.Stop();
        if (path is null)
            return;
        Process(path);
    }

    /// <summary>文件入口共用：对任意音频文件做带说话人分离的会议转写</summary>
    public void Process(string path, int? numSpeakers = null)
    {
        if (_state.Meeting == AppState.MeetingPhaseKind.Processing)
            return;
        _state.Meeting = AppState.MeetingPhaseKind.Processing;
        _state.MeetingStage = "准备…";
        _state.MeetingProgress = 0;
        _ = ProcessAsync(path, numSpeakers);
    }

    private async Task ProcessAsync(string path, int? numSpeakers)
    {
        try
        {
            var (_, jsonPath) = await _processor.ProcessAsync(
                path, numSpeakers,
                (stage, progress) => _ = App.Current.Dispatcher.InvokeAsync(() =>
                {
                    _state.Meeting = AppState.MeetingPhaseKind.Processing;
                    _state.MeetingStage = stage;
                    _state.MeetingProgress = progress;
                }));
            _state.Meeting = AppState.MeetingPhaseKind.Idle;
            _state.MeetingResultPath = jsonPath;
        }
        catch (Exception e)
        {
            _state.SetMeetingFailed($"会议处理失败：{e.Message}");
        }
    }

    public void Dispose()
    {
        _recorder.Dispose();
        _processor.Dispose();
    }
}
