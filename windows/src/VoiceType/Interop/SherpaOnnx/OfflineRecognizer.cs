using System.Runtime.InteropServices;

namespace VoiceType.Interop.SherpaOnnx;

/// <summary>
/// 离线识别器安全包装（SenseVoiceSmall / Fun-ASR-Nano-2512 / Qwen3-ASR-0.6B）。
/// 对应源工程 SherpaOnnxOfflineRecognizer 的使用面（decode(samples) → text）。
/// 非线程安全：由 AsrService 的串行队列独占调用。
/// </summary>
internal sealed class OfflineRecognizer : IDisposable
{
    private IntPtr _recognizer;

    private OfflineRecognizer(IntPtr recognizer) => _recognizer = recognizer;

    public static OfflineRecognizer Create(OfflineRecognizerOptions o)
    {
        using var pool = new NativeStringPool();
        var config = BuildConfig(o, pool);
        IntPtr p = SherpaOnnxNative.CreateOfflineRecognizer(ref config);
        if (p == IntPtr.Zero)
            throw new InvalidOperationException(
                "sherpa-onnx 创建识别器失败：模型文件缺失、不匹配或 DLL 版本不对（需要 v1.13.3 + onnxruntime 1.24.4）。");
        return new OfflineRecognizer(p);
    }

    internal static SherpaOnnxNative.OfflineRecognizerConfig BuildConfig(
        OfflineRecognizerOptions o, NativeStringPool pool)
    {
        var model = new SherpaOnnxNative.OfflineModelConfig
        {
            tokens = pool.Alloc(o.Tokens),
            num_threads = o.NumThreads,
            provider = pool.Alloc("cpu"),
        };
        switch (o.ModelKind)
        {
            case OfflineModelKind.SenseVoice:
                model.sense_voice = new SherpaOnnxNative.OfflineSenseVoiceModelConfig
                {
                    model = pool.Alloc(o.SenseVoice!.Model),
                    language = pool.Alloc(o.SenseVoice.Language),
                    use_itn = o.SenseVoice.UseInverseTextNormalization ? 1 : 0,
                };
                break;
            case OfflineModelKind.FunAsrNano:
                model.funasr_nano = new SherpaOnnxNative.OfflineFunASRNanoModelConfig
                {
                    encoder_adaptor = pool.Alloc(o.FunAsrNano!.EncoderAdaptor),
                    llm = pool.Alloc(o.FunAsrNano.Llm),
                    embedding = pool.Alloc(o.FunAsrNano.Embedding),
                    tokenizer = pool.Alloc(o.FunAsrNano.TokenizerDir),
                    max_new_tokens = o.FunAsrNano.MaxNewTokens,
                    temperature = 1e-6f,
                    top_p = 0.8f,
                    seed = 42,
                    itn = 1,
                };
                break;
            case OfflineModelKind.Qwen3Asr:
                model.qwen3_asr = new SherpaOnnxNative.OfflineQwen3ASRModelConfig
                {
                    conv_frontend = pool.Alloc(o.Qwen3Asr!.ConvFrontend),
                    encoder = pool.Alloc(o.Qwen3Asr.Encoder),
                    decoder = pool.Alloc(o.Qwen3Asr.Decoder),
                    tokenizer = pool.Alloc(o.Qwen3Asr.TokenizerDir),
                    max_total_len = 512,
                    max_new_tokens = o.Qwen3Asr.MaxNewTokens,
                    temperature = 1e-6f,
                    top_p = 0.8f,
                    seed = 42,
                };
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(o.ModelKind));
        }

        return new SherpaOnnxNative.OfflineRecognizerConfig
        {
            feat_config = new SherpaOnnxNative.FeatureConfig
            {
                sample_rate = 16000,
                feature_dim = 80,
            },
            model_config = model,
            decoding_method = pool.Alloc("greedy_search"),
            max_active_paths = 4,
        };
    }

    /// <summary>单段音频转写（16kHz 单声道 [-1,1]），返回纯文本。</summary>
    public string Decode(float[] samples, int sampleRate = 16000)
    {
        ObjectDisposedException.ThrowIf(_recognizer == IntPtr.Zero, this);
        IntPtr stream = SherpaOnnxNative.CreateOfflineStream(_recognizer);
        if (stream == IntPtr.Zero)
            throw new InvalidOperationException("sherpa-onnx 创建离线流失败");
        try
        {
            if (samples.Length > 0)
                SherpaOnnxNative.AcceptWaveformOffline(stream, sampleRate, samples, samples.Length);
            SherpaOnnxNative.DecodeOfflineStream(_recognizer, stream);
            IntPtr result = SherpaOnnxNative.GetOfflineStreamResult(stream);
            if (result == IntPtr.Zero)
                throw new InvalidOperationException("sherpa-onnx 获取识别结果失败");
            try
            {
                // c-api: sherpa_onnx_offline_recognizer_result 首字段为 const char* text
                return NativeUtf8.Read(Marshal.ReadIntPtr(result));
            }
            finally
            {
                SherpaOnnxNative.DestroyOfflineRecognizerResult(result);
            }
        }
        finally
        {
            SherpaOnnxNative.DestroyOfflineStream(stream);
        }
    }

    public void Dispose()
    {
        if (_recognizer != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyOfflineRecognizer(_recognizer);
            _recognizer = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    ~OfflineRecognizer() => Dispose();
}

internal enum OfflineModelKind
{
    SenseVoice,
    FunAsrNano,
    Qwen3Asr,
}

internal sealed class OfflineRecognizerOptions
{
    public OfflineModelKind ModelKind { get; init; }
    public int NumThreads { get; init; } = 4;
    public string Tokens { get; init; } = "";
    public SenseVoiceOptions? SenseVoice { get; init; }
    public FunAsrNanoOptions? FunAsrNano { get; init; }
    public Qwen3AsrOptions? Qwen3Asr { get; init; }
}

internal sealed class SenseVoiceOptions
{
    public string Model { get; init; } = "";
    public string Language { get; init; } = "auto";
    public bool UseInverseTextNormalization { get; init; } = true;
}

internal sealed class FunAsrNanoOptions
{
    public string EncoderAdaptor { get; init; } = "";
    public string Llm { get; init; } = "";
    public string Embedding { get; init; } = "";
    /// <summary>tokenizer 目录（vocab.json / merges.txt / tokenizer.json）</summary>
    public string TokenizerDir { get; init; } = "";
    public int MaxNewTokens { get; init; } = 512;
}

internal sealed class Qwen3AsrOptions
{
    public string ConvFrontend { get; init; } = "";
    public string Encoder { get; init; } = "";
    public string Decoder { get; init; } = "";
    /// <summary>tokenizer 目录（vocab.json / merges.txt / tokenizer_config.json）</summary>
    public string TokenizerDir { get; init; } = "";
    public int MaxNewTokens { get; init; } = 512;
}
