using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace VoiceType.Services;

public sealed class RecorderException : Exception
{
    public RecorderException(string message) : base(message) { }
}

/// <summary>
/// WASAPI 麦克风采集，实时重采样为 16kHz 单声道 Float32
/// （对应 macOS AVAudioEngine + AVAudioConverter 方案）。
/// 链路：WasapiCapture(共享模式, float) → MediaFoundationResampler(16k mono float)
///       → 累积全部采样 / chunk 回调（云端推流、会议落盘）/ RMS 电平（HUD）。
/// Start/Stop 需在 UI 线程调用；音频回调派发到 Start 时捕获的同步上下文（UI）。
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    private readonly object _lock = new();
    private List<float> _samples = [];
    private WasapiCapture? _capture;
    private WaveFormat _sourceFormat = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
    private BufferedWaveProvider? _buffered;
    private IWaveProvider? _resampler;
    private SynchronizationContext? _ui;
    private volatile bool _running;
    private readonly byte[] _readBuffer = new byte[16384];

    /// <summary>音频电平回调（0~1），UI 线程派发，供 HUD 显示</summary>
    public Action<float>? OnLevel { get; set; }

    /// <summary>转换后的 16k chunk 实时回调（UI 线程派发，云端推流/会议落盘用）</summary>
    public Action<float[]>? OnChunk { get; set; }

    public void Start()
    {
        WasapiCapture capture;
        try
        {
#pragma warning disable CS0618 // 3.x 推荐 WasapiRecorderBuilder，WasapiCapture 仍可用
            capture = new WasapiCapture();
#pragma warning restore CS0618
        }
        catch (Exception e)
        {
            throw new RecorderException(
                "无法打开麦克风（设备不存在或已被系统策略禁用）。请检查 Windows 设置 → 隐私和安全性 → 麦克风。" +
                $"（{e.Message}）");
        }

        WaveFormat src = capture.WaveFormat;
        if (src.SampleRate <= 0 || src.Channels <= 0)
        {
            capture.Dispose();
            throw new RecorderException("没有可用的麦克风输入设备");
        }

        _ui = SynchronizationContext.Current;
        _sourceFormat = src;
        lock (_lock)
        {
            _samples = [];
        }
        _running = true;

        capture.DataAvailable += OnDataAvailable;
        try
        {
            capture.StartRecording();
        }
        catch (Exception e)
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.Dispose();
            throw new RecorderException($"启动录音失败：{e.Message}");
        }
        _capture = capture;
    }

    /// <summary>返回本次录音的全部 16k 采样</summary>
    public float[] Stop()
    {
        WasapiCapture? capture = Interlocked.Exchange(ref _capture, null);
        if (capture is not null)
        {
            _running = false;
            try
            {
                capture.StopRecording();
            }
            catch
            {
                // 设备已拔出等情况，忽略
            }
            capture.DataAvailable -= OnDataAvailable;
            capture.Dispose();
            _resampler = null;
            _buffered = null;
        }
        lock (_lock)
        {
            float[] result = [.. _samples];
            _samples = [];
            return result;
        }
    }

    public void Dispose() => Stop();

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (!_running)
            return;
        // 缓冲与重采样器在采集回调线程上惰性创建并仅在该线程使用：
        // Media Foundation 对象有线程亲和性，不能 UI 线程建、回调线程用
        if (_resampler is null)
        {
            _buffered = new BufferedWaveProvider(_sourceFormat, TimeSpan.FromSeconds(60))
            {
                DiscardOnBufferOverflow = true,
                ReadFully = false,
            };
            _resampler = new MediaFoundationResampler(
                _buffered, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1))
            {
                ResamplerQuality = 60,
            };
        }
        BufferedWaveProvider buffered = _buffered;
        IWaveProvider resampler = _resampler;

        buffered.AddSamples(e.Buffer, 0, e.BytesRecorded);

        var chunk = new List<float>(4096);
        int read;
        while ((read = resampler.Read(_readBuffer)) > 0)
        {
            int floatCount = read / 4;
            var floats = new float[floatCount];
            System.Buffer.BlockCopy(_readBuffer, 0, floats, 0, read);
            lock (_lock)
            {
                _samples.AddRange(floats);
            }
            chunk.AddRange(floats);
        }

        if (chunk.Count == 0)
            return;

        float sum = 0;
        foreach (float v in chunk)
            sum += v * v;
        float rms = MathF.Sqrt(sum / Math.Max(chunk.Count, 1));
        float level = MathF.Min(1f, rms * 12f);

        Dispatch(() =>
        {
            OnLevel?.Invoke(level);
            OnChunk?.Invoke([.. chunk]);
        });
    }

    private void Dispatch(Action action)
    {
        SynchronizationContext? ui = _ui;
        if (ui is not null)
            ui.Post(_ => action(), null);
        else
            Task.Run(action);
    }
}

/// <summary>
/// 调试辅助：保留最近一次听写实际送入 ASR 的音频（16k mono float wav），
/// 用于区分"采集链路问题"与"模型识别问题"。仅保留最后一次，体积极小。
/// </summary>
public static class DebugAudioDump
{
    public static string LastDictationPath =>
        Path.Combine(ModelPaths.AppDataRoot, "debug", "last-dictation.wav");

    public static void Write(float[] samples)
    {
        if (samples.Length == 0)
            return;
        try
        {
            string path = LastDictationPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.Delete(path);
            using var writer = new WaveFileWriter(
                path, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1));
            writer.WriteSamples(samples, 0, samples.Length);
        }
        catch
        {
            // 调试转储失败无所谓
        }
    }
}
