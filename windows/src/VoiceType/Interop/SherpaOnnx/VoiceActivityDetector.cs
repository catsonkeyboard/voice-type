using System.Runtime.InteropServices;

namespace VoiceType.Interop.SherpaOnnx;

/// <summary>silero VAD 安全包装。非线程安全：由调用方的串行队列独占调用。</summary>
internal sealed class VoiceActivityDetector : IDisposable
{
    private IntPtr _vad;

    private VoiceActivityDetector(IntPtr vad) => _vad = vad;

    public static VoiceActivityDetector Create(VadOptions o)
    {
        using var pool = new NativeStringPool();
        var config = new SherpaOnnxNative.VadModelConfig
        {
            silero_vad = new SherpaOnnxNative.SileroVadModelConfig
            {
                model = pool.Alloc(o.Model),
                threshold = o.Threshold,
                min_silence_duration = o.MinSilenceDuration,
                min_speech_duration = o.MinSpeechDuration,
                window_size = o.WindowSize,
                max_speech_duration = o.MaxSpeechDuration,
            },
            sample_rate = 16000,
            num_threads = 1,
            provider = pool.Alloc("cpu"),
        };
        IntPtr p = SherpaOnnxNative.CreateVoiceActivityDetector(ref config, o.BufferSizeInSeconds);
        if (p == IntPtr.Zero)
            throw new InvalidOperationException("sherpa-onnx 创建 VAD 失败（silero_vad.onnx 缺失？）");
        return new VoiceActivityDetector(p);
    }

    public void AcceptWaveform(float[] samples) =>
        SherpaOnnxNative.VadAcceptWaveform(_vad, samples, samples.Length);

    public bool IsEmpty() => SherpaOnnxNative.VadIsEmpty(_vad) == 1;

    public bool IsSpeechDetected() => SherpaOnnxNative.VadIsDetected(_vad) == 1;

    public void Pop() => SherpaOnnxNative.VadPop(_vad);

    public void Clear() => SherpaOnnxNative.VadClear(_vad);

    public void Reset() => SherpaOnnxNative.VadReset(_vad);

    public void Flush() => SherpaOnnxNative.VadFlush(_vad);

    /// <summary>取队首语音段（拷贝样本）；调用后需 Pop()。</summary>
    public SpeechSegmentData Front()
    {
        IntPtr p = SherpaOnnxNative.VadFront(_vad);
        if (p == IntPtr.Zero)
            throw new InvalidOperationException("sherpa-onnx VAD 队列为空");
        var seg = Marshal.PtrToStructure<SherpaOnnxNative.SpeechSegment>(p);
        var samples = new float[seg.n];
        if (seg.n > 0 && seg.samples != IntPtr.Zero)
            Marshal.Copy(seg.samples, samples, 0, seg.n);
        return new SpeechSegmentData(seg.start, samples);
    }

    public void Dispose()
    {
        if (_vad != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyVoiceActivityDetector(_vad);
            _vad = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    ~VoiceActivityDetector() => Dispose();
}

internal readonly record struct SpeechSegmentData(int Start, float[] Samples);

internal sealed class VadOptions
{
    public string Model { get; init; } = "";
    public float Threshold { get; init; } = 0.5f;
    public float MinSilenceDuration { get; init; } = 0.5f;
    public float MinSpeechDuration { get; init; } = 0.25f;
    public int WindowSize { get; init; } = 512;
    public float MaxSpeechDuration { get; init; } = 5f;
    /// <summary>环形缓冲容量（秒），须大于单段最大时长</summary>
    public float BufferSizeInSeconds { get; init; } = 120f;
}
