namespace VoiceType.Services;

/// <summary>
/// 模型文件布局（与 macOS 端完全一致，模型跨平台通用）。
/// 根目录：%APPDATA%\VoiceType\models
/// </summary>
public static class ModelPaths
{
    public static string AppDataRoot { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VoiceType");

    public static string ModelsDir => Path.Combine(AppDataRoot, "models");

    // ----- SenseVoice（历史布局，位于 models/ 根）-----

    public static string AsrModel => Path.Combine(ModelsDir, "model.int8.onnx");
    public static string Tokens => Path.Combine(ModelsDir, "tokens.txt");

    // ----- Fun-ASR-Nano-2512（models/funasr-nano/）-----

    public static string FunasrDir => Path.Combine(ModelsDir, "funasr-nano");
    public static string FunasrEncoder => Path.Combine(FunasrDir, "encoder_adaptor.int8.onnx");
    public static string FunasrLlm => Path.Combine(FunasrDir, "llm.int8.onnx");
    public static string FunasrEmbedding => Path.Combine(FunasrDir, "embedding.int8.onnx");
    /// <summary>tokenizer 目录（vocab.json / merges.txt / tokenizer.json）</summary>
    public static string FunasrTokenizer => Path.Combine(FunasrDir, "Qwen3-0.6B");

    // ----- Qwen3-ASR-0.6B（models/qwen3-asr/）-----

    public static string Qwen3Dir => Path.Combine(ModelsDir, "qwen3-asr");
    public static string Qwen3ConvFrontend => Path.Combine(Qwen3Dir, "conv_frontend.onnx");
    public static string Qwen3Encoder => Path.Combine(Qwen3Dir, "encoder.int8.onnx");
    public static string Qwen3Decoder => Path.Combine(Qwen3Dir, "decoder.int8.onnx");
    /// <summary>tokenizer 目录（vocab.json / merges.txt / tokenizer_config.json，无 tokenizer.json）</summary>
    public static string Qwen3Tokenizer => Path.Combine(Qwen3Dir, "tokenizer");

    // ----- 公共组件 -----

    public static string VadModel => Path.Combine(ModelsDir, "silero_vad.onnx");
    public static string SegmentationModel => Path.Combine(ModelsDir, "segmentation.onnx");
    public static string SpeakerEmbeddingModel => Path.Combine(ModelsDir, "speaker-embedding.onnx");

    public static bool VadPresent => File.Exists(VadModel);

    public static bool DiarizationPresent =>
        File.Exists(SegmentationModel) && File.Exists(SpeakerEmbeddingModel);

    /// <summary>指定档位的模型文件是否全部就位。</summary>
    public static bool IsPresent(LocalAsrModel model) => model switch
    {
        LocalAsrModel.SenseVoice => File.Exists(AsrModel) && File.Exists(Tokens),
        LocalAsrModel.FunasrNano =>
            File.Exists(FunasrEncoder) && File.Exists(FunasrLlm) && File.Exists(FunasrEmbedding)
            && new[] { "vocab.json", "merges.txt", "tokenizer.json" }
                .All(f => File.Exists(Path.Combine(FunasrTokenizer, f))),
        LocalAsrModel.Qwen3Asr =>
            File.Exists(Qwen3ConvFrontend) && File.Exists(Qwen3Encoder) && File.Exists(Qwen3Decoder)
            && new[] { "vocab.json", "merges.txt", "tokenizer_config.json" }
                .All(f => File.Exists(Path.Combine(Qwen3Tokenizer, f))),
        _ => false,
    };
}
