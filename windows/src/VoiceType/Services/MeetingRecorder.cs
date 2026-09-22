using NAudio.Wave;
using VoiceType.Models;

namespace VoiceType.Services;

/// <summary>
/// 会议长录音：chunk 实时写 wav 落盘（内存占用恒定，App 崩溃录音不丢）。
/// 格式 16kHz mono IEEE float（macOS 端为 AVAudioFile 同格式）。
/// </summary>
public sealed class MeetingRecorder : IDisposable
{
    public const double MaxSeconds = 3 * 3600;

    private readonly AudioRecorder _recorder = new();
    private readonly object _fileLock = new();
    private WaveFileWriter? _file;
    private DateTime? _startedAt;
    private string? _filePath;
    private bool _autoStopFired;
    private readonly System.Timers.Timer _checkTimer = new() { Interval = 2000 };

    public MeetingRecorder() => _checkTimer.Elapsed += (_, _) => CheckAutoStop();

    /// <summary>到达时长上限时回调（UI 线程）</summary>
    public Action? OnAutoStop { get; set; }

    public bool IsRecording => _startedAt is not null;

    public string? Start()
    {
        string dir = MeetingTranscript.MeetingsDir;
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, $"{DateTime.Now:yyyyMMdd-HHmmss}.wav");
        _file = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1));
        _filePath = path;
        _autoStopFired = false;
        _recorder.OnChunk = chunk =>
        {
            // OnChunk 已在 UI 线程派发；写盘很快，可接受
            Append(chunk);
        };
        _recorder.Start();
        _startedAt = DateTime.Now;
        _checkTimer.Start();
        return path;
    }

    private void Append(float[] chunk)
    {
        WaveFileWriter? file;
        lock (_fileLock)
            file = _file;
        if (file is null || chunk.Length == 0)
            return;
        lock (file)
        {
            file.WriteSamples(chunk, 0, chunk.Length);
        }
        CheckAutoStop();
    }

    private void CheckAutoStop()
    {
        if (_startedAt is null || _autoStopFired)
            return;
        if ((DateTime.Now - _startedAt.Value).TotalSeconds < MaxSeconds)
            return;
        _autoStopFired = true;
        OnAutoStop?.Invoke();
    }

    /// <summary>返回录音文件；未在录音时返回 null</summary>
    public string? Stop()
    {
        if (!IsRecording)
            return null;
        _checkTimer.Stop();
        _recorder.Stop();
        _recorder.OnChunk = null;
        lock (_fileLock)
        {
            _file?.Dispose();
            _file = null;
        }
        _startedAt = null;
        string? path = _filePath;
        _filePath = null;
        return path;
    }

    public void Dispose()
    {
        _ = Stop();
        _recorder.Dispose();
        _checkTimer.Dispose();
    }
}
