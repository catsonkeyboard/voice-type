using VoiceType.Interop.SherpaOnnx;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

/// <summary>
/// P/Invoke 冒烟（集成测试）：验证 SherpaOnnxNative 结构体布局与入口点名
/// 与 v1.13.3 win-x64 DLL 匹配。依赖已安装的模型与原生 DLL，默认过滤：
///   dotnet test --filter Category!=Integration
/// 运行：dotnet test --filter Category=Integration
/// </summary>
[Trait("Category", "Integration")]
public class SherpaOnnxInteropTests
{

    private static float[] Silence(double seconds, double sr = 16000) =>
        new float[(int)(seconds * sr)];

    [Fact]
    public void OfflineRecognizer_SenseVoice_DecodesRealSpeech()
    {
        if (!ModelPaths.IsPresent(LocalAsrModel.SenseVoice))
            throw new SkipException("SenseVoice 模型未安装（scripts/export_sensevoice.ps1）");
        string wav = Path.Combine(ModelPaths.FunasrDir, "test_wavs", "dia_sh.wav");
        if (!File.Exists(wav))
            throw new SkipException("测试音频缺失: " + wav);

        using var recognizer = OfflineRecognizer.Create(new OfflineRecognizerOptions
        {
            ModelKind = OfflineModelKind.SenseVoice,
            NumThreads = 4,
            Tokens = ModelPaths.Tokens,
            SenseVoice = new SenseVoiceOptions
            {
                Model = ModelPaths.AsrModel,
                Language = "auto",
                UseInverseTextNormalization = true,
            },
        });
        float[] samples = ReadWav16kMono(wav);
        string text = recognizer.Decode(samples).Trim();
        Assert.False(string.IsNullOrEmpty(text), "真实语音解码输出为空");
        Assert.True(text.Length < 500, $"输出异常: {text}");
    }

    [Fact]
    public void OfflineRecognizer_FunAsrNano_DecodesRealSpeech()
    {
        if (!ModelPaths.IsPresent(LocalAsrModel.FunasrNano))
        {
            throw new SkipException("funasr-nano 模型未安装（scripts/download_models.ps1 funasr-nano）");
        }
        string wav = Path.Combine(ModelPaths.FunasrDir, "test_wavs", "dia_sh.wav");
        if (!File.Exists(wav))
            throw new SkipException("测试音频缺失: " + wav);

        using var recognizer = OfflineRecognizer.Create(new OfflineRecognizerOptions
        {
            ModelKind = OfflineModelKind.FunAsrNano,
            NumThreads = 4,
            FunAsrNano = new FunAsrNanoOptions
            {
                EncoderAdaptor = ModelPaths.FunasrEncoder,
                Llm = ModelPaths.FunasrLlm,
                Embedding = ModelPaths.FunasrEmbedding,
                TokenizerDir = ModelPaths.FunasrTokenizer,
            },
        });
        float[] samples = ReadWav16kMono(wav);
        string text = recognizer.Decode(samples).Trim();
        // 上海话测试音频：真实语音应输出非空中文文本（这是对结构体布局/UTF-8 封送的端到端验证）
        Assert.False(string.IsNullOrEmpty(text), "真实语音解码输出为空");
        Assert.True(text.Length < 500, $"输出异常: {text}");
        Console.WriteLine($"识别结果: {text}");
    }

    private static float[] ReadWav16kMono(string path)
    {
        using var reader = new NAudio.Wave.AudioFileReader(path);
        // AudioFileReader 输出 float；重采样到 16k 单声道
        if (reader.WaveFormat.SampleRate == 16000 && reader.WaveFormat.Channels == 1)
        {
            var direct = new float[reader.Length / 4];
            int read = reader.Read(direct.AsSpan());
            return direct[..read];
        }
        using var resampler = new NAudio.Wave.MediaFoundationResampler(
            reader, NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(16000, 1));
        var buffer = new byte[1 << 16];
        var result = new List<float>(1 << 16);
        int r;
        while ((r = resampler.Read(buffer)) > 0)
        {
            var floats = new float[r / 4];
            System.Buffer.BlockCopy(buffer, 0, floats, 0, r);
            result.AddRange(floats);
        }
        return [.. result];
    }

    [Fact]
    public void VoiceActivityDetector_FlushesSilenceAsEmpty()
    {
        if (!ModelPaths.VadPresent)
        {
            throw new SkipException("silero_vad.onnx 未安装");
        }
        using var vad = VoiceActivityDetector.Create(new VadOptions
        {
            Model = ModelPaths.VadModel,
            Threshold = 0.5f,
            MinSilenceDuration = 0.5f,
            MinSpeechDuration = 0.25f,
            WindowSize = 512,
            MaxSpeechDuration = 5f,
            BufferSizeInSeconds = 30,
        });
        // 纯静音：分段队列应为空
        float[] samples = Silence(1.0);
        for (int i = 0; i < samples.Length; i += 512)
        {
            vad.AcceptWaveform(samples[i..Math.Min(i + 512, samples.Length)]);
        }
        vad.Flush();
        Assert.True(vad.IsEmpty());
    }
}

/// <summary>跳过（环境不满足）而非失败。</summary>
public sealed class SkipException : Xunit.Sdk.XunitException
{
    public SkipException(string message) : base(message) { }
}
