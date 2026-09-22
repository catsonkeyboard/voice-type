using VoiceType.Services;
using VoiceType.UI;

namespace VoiceType.Core;

/// <summary>
/// 组装全部服务（对应 macOS AppDependencies），进程内单例。
/// 在 UI 线程构造（AudioRecorder 捕获同步上下文、HudController 需要 Dispatcher）。
/// </summary>
public sealed class AppDependencies
{
    public static AppDependencies Shared { get; } = new();

    public AppState State { get; }
    public SettingsStore Settings { get; }
    public HistoryStore History { get; }
    public AsrService Asr { get; }
    public PolishService Polish { get; }
    public DictationController Dictation { get; }
    public MeetingController Meeting { get; }

    private AppDependencies()
    {
        Settings = SettingsStore.Default;
        State = new AppState();
        History = new HistoryStore();
        Asr = new AsrService(Settings);
        Polish = new PolishService();
        Dictation = new DictationController(State, Asr, History, Polish, Settings);
        Meeting = new MeetingController(State, Asr);

        HotkeyManager.Shared.OnHotkey += Dictation.Toggle;
        _ = HotkeyManager.Shared.Register(Settings.KeyCombo);
        Asr.WarmUp();
        if (Settings.PolishEnabled)
            Polish.WarmUp();
    }
}
