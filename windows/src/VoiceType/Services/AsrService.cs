using VoiceType.Interop.SherpaOnnx;

namespace VoiceType.Services;

public sealed class AsrException : Exception
{
    public AsrException(string message) : base(message) { }
}

/// <summary>
/// 离线识别服务（sherpa-onnx）：SenseVoiceSmall / Fun-ASR-Nano-2512 / Qwen3-ASR-0.6B。
/// 推理在串行信号量保护下执行（对应 macOS 专用串行队列），模型常驻内存；
/// 切换档位后调用 Reload() 重建。
/// </summary>
public sealed class AsrService : IDisposable
{
    /// <summary>LLM 型模型存在 max_total_len（≈512 token ≈ 20s 音频）截断上限，
    /// 超过该时长的单次转写先经 VAD 分段再逐段识别。</summary>
    private const double LlmMaxDirectSeconds = 20;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Func<SettingsStore> _settings;
    private OfflineRecognizer? _recognizer;
    private LocalAsrModel? _loadedModel;

    public AsrService(SettingsStore? settings = null)
    {
        _settings = () => settings ?? SettingsStore.Default;
    }

    private SettingsStore Settings => _settings();

    private static bool IsLlm(LocalAsrModel model) =>
        model is LocalAsrModel.FunasrNano or LocalAsrModel.Qwen3Asr;

    /// <summary>预热：后台加载当前档位模型（App 启动时调用）</summary>
    public void WarmUp() => _ = Task.Run(async () =>
    {
        await _gate.WaitAsync();
        try { _ = LoadedRecognizer(); }
        catch { /* 启动期模型未安装属正常态，不抛 */ }
        finally { _gate.Release(); }
    });

    /// <summary>切换档位后调用：释放旧模型并立即按新档位重载</summary>
    public async Task ReloadAsync()
    {
        await _gate.WaitAsync();
        try
        {
            _recognizer?.Dispose();
            _recognizer = null;
            _loadedModel = null;
            _ = LoadedRecognizer();
        }
        finally
        {
            _gate.Release();
        }
    }

    private OfflineRecognizer LoadedRecognizer()
    {
        LocalAsrModel model = Settings.LocalAsrModel;
        if (_recognizer is not null && _loadedModel == model)
            return _recognizer;
        if (!ModelPaths.IsPresent(model))
            throw new AsrException(
                $"本地识别模型未安装（{model.Label()}），请在项目目录运行 {model.InstallCommand()}");

        var options = new OfflineRecognizerOptions
        {
            ModelKind = model switch
            {
                LocalAsrModel.SenseVoice => OfflineModelKind.SenseVoice,
                LocalAsrModel.FunasrNano => OfflineModelKind.FunAsrNano,
                LocalAsrModel.Qwen3Asr => OfflineModelKind.Qwen3Asr,
                _ => throw new ArgumentOutOfRangeException(),
            },
            NumThreads = 4,
            Tokens = ModelPaths.Tokens,
            SenseVoice = new SenseVoiceOptions
            {
                Model = ModelPaths.AsrModel,
                Language = "auto",
                UseInverseTextNormalization = true,
            },
            FunAsrNano = new FunAsrNanoOptions
            {
                EncoderAdaptor = ModelPaths.FunasrEncoder,
                Llm = ModelPaths.FunasrLlm,
                Embedding = ModelPaths.FunasrEmbedding,
                TokenizerDir = ModelPaths.FunasrTokenizer,
                MaxNewTokens = 512,
            },
            Qwen3Asr = new Qwen3AsrOptions
            {
                ConvFrontend = ModelPaths.Qwen3ConvFrontend,
                Encoder = ModelPaths.Qwen3Encoder,
                Decoder = ModelPaths.Qwen3Decoder,
                TokenizerDir = ModelPaths.Qwen3Tokenizer,
                MaxNewTokens = 512,
            },
        };
        var r = OfflineRecognizer.Create(options);
        _recognizer = r;
        _loadedModel = model;
        return r;
    }

    /// <summary>单段音频转写（16kHz 单声道）。LLM 模型超 20s 时自动 VAD 分段。
    /// 推理在信号量串行 + 线程池执行，调用方（UI）不阻塞。</summary>
    public async Task<string> TranscribeAsync(
        float[] samples, int sampleRate = 16000, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            return await Task.Run(() => TranscribeSync(samples, sampleRate), ct);
        }
        finally
        {
            _gate.Release();
        }
    }

    private string TranscribeSync(float[] samples, int sampleRate)
    {
        OfflineRecognizer r = LoadedRecognizer();
        double duration = samples.Length / (double)Math.Max(sampleRate, 1);
        if (IsLlm(Settings.LocalAsrModel) && duration > LlmMaxDirectSeconds)
        {
            List<string> pieces = VadTranscribe(samples, r, maxSpeechDuration: 15f, null);
            return string.Join("\n", pieces);
        }
        return r.Decode(samples, sampleRate).Trim();
    }

    /// <summary>文件转写：解码 → silero VAD 分段 → 逐段识别，段间换行</summary>
    public async Task<string> TranscribeFileAsync(
        string path, Action<double>? onProgress = null, CancellationToken ct = default)
    {
        float[] samples = AudioFileDecoder.Decode16kMono(path);
        float maxSpeech = IsLlm(Settings.LocalAsrModel) ? 15f : 20f;
        await _gate.WaitAsync(ct);
        try
        {
            OfflineRecognizer r = LoadedRecognizer();
            List<string> pieces = await Task.Run(
                () => VadTranscribe(samples, r, maxSpeech, onProgress), ct);
            return string.Join("\n", pieces);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>VAD 切分 + 逐段识别。LLM 模型 maxSpeechDuration 取 15s（防 max_total_len 截断），
    /// SenseVoice 沿用 20s。空段自动丢弃。</summary>
    private static List<string> VadTranscribe(
        float[] samples, OfflineRecognizer recognizer, float maxSpeechDuration,
        Action<double>? onProgress)
    {
        if (!ModelPaths.VadPresent)
            throw new AsrException("VAD 模型未安装，请运行 .\\windows\\scripts\\download_models.ps1 或 export_sensevoice.ps1");
        using var vad = VoiceActivityDetector.Create(new VadOptions
        {
            Model = ModelPaths.VadModel,
            Threshold = 0.5f,
            MinSilenceDuration = 0.5f,
            MinSpeechDuration = 0.25f,
            WindowSize = 512,
            MaxSpeechDuration = maxSpeechDuration,
            BufferSizeInSeconds = 120,
        });

        var pieces = new List<string>();
        void DrainSegments()
        {
            while (!vad.IsEmpty())
            {
                SpeechSegmentData seg = vad.Front();
                string text = recognizer.Decode(seg.Samples).Trim();
                if (text.Length > 0)
                    pieces.Add(text);
                vad.Pop();
            }
        }

        const int window = 512;
        int i = 0;
        while (i < samples.Length)
        {
            int end = Math.Min(i + window, samples.Length);
            vad.AcceptWaveform(samples[i..end]);
            DrainSegments();
            i = end;
            onProgress?.Invoke(i / (double)Math.Max(samples.Length, 1));
        }
        vad.Flush();
        DrainSegments();
        return pieces;
    }

    public void Dispose()
    {
        _recognizer?.Dispose();
        _recognizer = null;
        _loadedModel = null;
        _gate.Dispose();
    }
}
