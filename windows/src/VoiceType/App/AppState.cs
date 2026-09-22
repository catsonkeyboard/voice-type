using CommunityToolkit.Mvvm.ComponentModel;
using VoiceType.Models;
using VoiceType.Services;

namespace VoiceType.Core;

/// <summary>全局可观察状态（对应 Swift @Observable AppState），供多窗口共享绑定。</summary>
public partial class AppState : ObservableObject
{
    public enum PhaseKind { Idle, Recording, Transcribing, Polishing, Error }

    public enum FileJobKind { Idle, Running, Done, Failed }

    public enum MeetingPhaseKind { Idle, Recording, Processing, Failed }

    [ObservableProperty] private PhaseKind _phase = PhaseKind.Idle;
    [ObservableProperty] private string? _phaseError;
    [ObservableProperty] private float _micLevel;
    /// <summary>云端识别的实时中间结果（仅云端引擎录音阶段非空）</summary>
    [ObservableProperty] private string? _partialText;
    /// <summary>HUD 上的一次性提示（如"已复制到剪贴板"），显示后由 HudController 清除</summary>
    [ObservableProperty] private string? _hudMessage;

    [ObservableProperty] private FileJobKind _fileJob = FileJobKind.Idle;
    [ObservableProperty] private double _fileJobProgress;
    [ObservableProperty] private string? _fileJobText;

    [ObservableProperty] private MeetingPhaseKind _meeting = MeetingPhaseKind.Idle;
    [ObservableProperty] private string? _meetingError;
    [ObservableProperty] private DateTime? _meetingStartedAt;
    [ObservableProperty] private string? _meetingStage;
    [ObservableProperty] private double _meetingProgress;
    /// <summary>最近一次会议稿 JSON 路径（结果窗口入口）</summary>
    [ObservableProperty] private string? _meetingResultPath;

    [ObservableProperty] private bool _modelsReady = ModelPaths.IsPresent(
        Services.SettingsStore.Default.LocalAsrModel);

    public void RefreshModelsReady() =>
        ModelsReady = ModelPaths.IsPresent(Services.SettingsStore.Default.LocalAsrModel);

    public void SetPhaseError(string message)
    {
        Phase = PhaseKind.Error;
        PhaseError = message;
    }

    public void SetFileJobFailed(string message)
    {
        FileJob = FileJobKind.Failed;
        FileJobText = message;
    }

    public void SetMeetingFailed(string message)
    {
        Meeting = MeetingPhaseKind.Failed;
        MeetingError = message;
    }
}
