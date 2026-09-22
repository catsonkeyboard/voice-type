using System.Runtime.InteropServices;

namespace VoiceType.Interop.SherpaOnnx;

/// <summary>
/// sherpa-onnx C API（c-api.h，版本锁定 v1.13.3 / onnxruntime 1.24.4）的 P/Invoke 声明。
/// 结构体布局与字段顺序必须与 c-api.h 完全一致（源工程 Vendored 的 Swift 绑定
/// 工厂函数参数顺序即 C 声明顺序，双源核对）；头文件随 fetch_deps.ps1 落在
/// Interop/SherpaOnnx/include/sherpa-onnx/c-api/c-api.h 可供复核。
/// DLL 由 scripts/fetch_deps.ps1 放在应用目录，随构建复制。
/// </summary>
internal static class SherpaOnnxNative
{
    internal const string DllName = "sherpa-onnx-c-api";

    // ---------------- 特征配置 ----------------

    [StructLayout(LayoutKind.Sequential)]
    internal struct FeatureConfig
    {
        public int sample_rate;
        public int feature_dim;
    }

    // ---------------- 离线识别：子模型配置 ----------------

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineTransducerModelConfig
    {
        public IntPtr encoder;
        public IntPtr decoder;
        public IntPtr joiner;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineParaformerModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineNemoEncDecCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineWhisperModelConfig
    {
        public IntPtr encoder;
        public IntPtr decoder;
        public IntPtr language;
        public IntPtr task;
        public int tail_paddings;
        public int enable_token_timestamps;
        public int enable_segment_timestamps;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineTdnnModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineLMConfig
    {
        public IntPtr model;
        public float scale;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineSenseVoiceModelConfig
    {
        public IntPtr model;
        public IntPtr language;
        public int use_itn;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineMoonshineModelConfig
    {
        public IntPtr preprocessor;
        public IntPtr encoder;
        public IntPtr uncached_decoder;
        public IntPtr cached_decoder;
        public IntPtr merged_decoder;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineFireRedAsrModelConfig
    {
        public IntPtr encoder;
        public IntPtr decoder;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineDolphinModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineZipformerCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineCanaryModelConfig
    {
        public IntPtr encoder;
        public IntPtr decoder;
        public IntPtr src_lang;
        public IntPtr tgt_lang;
        public int use_pnc;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineWenetCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineOmnilingualAsrCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineMedAsrCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineFunASRNanoModelConfig
    {
        public IntPtr encoder_adaptor;
        public IntPtr llm;
        public IntPtr embedding;
        public IntPtr tokenizer;
        public IntPtr system_prompt;
        public IntPtr user_prompt;
        public int max_new_tokens;
        public float temperature;
        public float top_p;
        public int seed;
        public IntPtr language;
        public int itn;
        public IntPtr hotwords;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineFireRedAsrCtcModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineQwen3ASRModelConfig
    {
        public IntPtr conv_frontend;
        public IntPtr encoder;
        public IntPtr decoder;
        public IntPtr tokenizer;
        public int max_total_len;
        public int max_new_tokens;
        public float temperature;
        public float top_p;
        public int seed;
        public IntPtr hotwords;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineCohereTranscribeModelConfig
    {
        public IntPtr encoder;
        public IntPtr decoder;
        public IntPtr language;
        public int use_punct;
        public int use_itn;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HomophoneReplacerConfig
    {
        public IntPtr dict_dir;
        public IntPtr lexicon;
        public IntPtr rule_fsts;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineModelConfig
    {
        public OfflineTransducerModelConfig transducer;
        public OfflineParaformerModelConfig paraformer;
        public OfflineNemoEncDecCtcModelConfig nemo_ctc;
        public OfflineWhisperModelConfig whisper;
        public OfflineTdnnModelConfig tdnn;
        public IntPtr tokens;
        public int num_threads;
        public int debug;
        public IntPtr provider;
        public IntPtr model_type;
        public IntPtr modeling_unit;
        public IntPtr bpe_vocab;
        public IntPtr telespeech_ctc;
        public OfflineSenseVoiceModelConfig sense_voice;
        public OfflineMoonshineModelConfig moonshine;
        public OfflineFireRedAsrModelConfig fire_red_asr;
        public OfflineDolphinModelConfig dolphin;
        public OfflineZipformerCtcModelConfig zipformer_ctc;
        public OfflineCanaryModelConfig canary;
        public OfflineWenetCtcModelConfig wenet_ctc;
        public OfflineOmnilingualAsrCtcModelConfig omnilingual;
        public OfflineMedAsrCtcModelConfig medasr;
        public OfflineFunASRNanoModelConfig funasr_nano;
        public OfflineFireRedAsrCtcModelConfig fire_red_asr_ctc;
        public OfflineQwen3ASRModelConfig qwen3_asr;
        public OfflineCohereTranscribeModelConfig cohere_transcribe;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineRecognizerConfig
    {
        public FeatureConfig feat_config;
        public OfflineModelConfig model_config;
        public OfflineLMConfig lm_config;
        public IntPtr decoding_method;
        public int max_active_paths;
        public IntPtr hotwords_file;
        public float hotwords_score;
        public IntPtr rule_fsts;
        public IntPtr rule_fars;
        public float blank_penalty;
        public HomophoneReplacerConfig hr;
    }

    // ---------------- VAD ----------------

    [StructLayout(LayoutKind.Sequential)]
    internal struct SileroVadModelConfig
    {
        public IntPtr model;
        public float threshold;
        public float min_silence_duration;
        public float min_speech_duration;
        public int window_size;
        public float max_speech_duration;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TenVadModelConfig
    {
        public IntPtr model;
        public float threshold;
        public float min_silence_duration;
        public float min_speech_duration;
        public int window_size;
        public float max_speech_duration;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct VadModelConfig
    {
        public SileroVadModelConfig silero_vad;
        public int sample_rate;
        public int num_threads;
        public IntPtr provider;
        public int debug;
        public TenVadModelConfig ten_vad;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SpeechSegment
    {
        public int start;
        public IntPtr samples;
        public int n;
    }

    // ---------------- 说话人分离 ----------------

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineSpeakerSegmentationPyannoteModelConfig
    {
        public IntPtr model;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineSpeakerSegmentationModelConfig
    {
        public OfflineSpeakerSegmentationPyannoteModelConfig pyannote;
        public int num_threads;
        public int debug;
        public IntPtr provider;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SpeakerEmbeddingExtractorConfig
    {
        public IntPtr model;
        public int num_threads;
        public int debug;
        public IntPtr provider;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FastClusteringConfig
    {
        public int num_clusters;
        public float threshold;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineSpeakerDiarizationConfig
    {
        public OfflineSpeakerSegmentationModelConfig segmentation;
        public SpeakerEmbeddingExtractorConfig embedding;
        public FastClusteringConfig clustering;
        public float min_duration_on;
        public float min_duration_off;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OfflineSpeakerDiarizationSegment
    {
        public float start;
        public float end;
        public int speaker;
    }

    // ---------------- 离线识别函数 ----------------

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxCreateOfflineRecognizer")]
    internal static extern IntPtr CreateOfflineRecognizer(ref OfflineRecognizerConfig config);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroyOfflineRecognizer")]
    internal static extern void DestroyOfflineRecognizer(IntPtr recognizer);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxCreateOfflineStream")]
    internal static extern IntPtr CreateOfflineStream(IntPtr recognizer);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroyOfflineStream")]
    internal static extern void DestroyOfflineStream(IntPtr stream);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxAcceptWaveformOffline")]
    internal static extern void AcceptWaveformOffline(
        IntPtr stream, int sampleRate, float[] samples, int n);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDecodeOfflineStream")]
    internal static extern void DecodeOfflineStream(IntPtr recognizer, IntPtr stream);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxGetOfflineStreamResult")]
    internal static extern IntPtr GetOfflineStreamResult(IntPtr stream);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroyOfflineRecognizerResult")]
    internal static extern void DestroyOfflineRecognizerResult(IntPtr result);

    // ---------------- VAD 函数 ----------------

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxCreateVoiceActivityDetector")]
    internal static extern IntPtr CreateVoiceActivityDetector(
        ref VadModelConfig config, float bufferSizeInSeconds);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroyVoiceActivityDetector")]
    internal static extern void DestroyVoiceActivityDetector(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorAcceptWaveform")]
    internal static extern void VadAcceptWaveform(IntPtr vad, float[] samples, int n);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorEmpty")]
    internal static extern int VadIsEmpty(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorDetected")]
    internal static extern int VadIsDetected(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorFront")]
    internal static extern IntPtr VadFront(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorPop")]
    internal static extern void VadPop(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorClear")]
    internal static extern void VadClear(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorReset")]
    internal static extern void VadReset(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxVoiceActivityDetectorFlush")]
    internal static extern void VadFlush(IntPtr vad);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroySpeechSegment")]
    internal static extern void DestroySpeechSegment(IntPtr segment);

    // ---------------- 说话人分离函数 ----------------

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxCreateOfflineSpeakerDiarization")]
    internal static extern IntPtr CreateOfflineSpeakerDiarization(
        ref OfflineSpeakerDiarizationConfig config);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxDestroyOfflineSpeakerDiarization")]
    internal static extern void DestroyOfflineSpeakerDiarization(IntPtr sd);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationGetSampleRate")]
    internal static extern int SpeakerDiarizationGetSampleRate(IntPtr sd);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationProcess")]
    internal static extern IntPtr SpeakerDiarizationProcess(
        IntPtr sd, float[] samples, int n);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments")]
    internal static extern int SpeakerDiarizationResultGetNumSegments(IntPtr result);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime")]
    internal static extern IntPtr SpeakerDiarizationResultSortByStartTime(IntPtr result);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationDestroySegment")]
    internal static extern void SpeakerDiarizationDestroySegment(IntPtr segments);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl,
        EntryPoint = "SherpaOnnxOfflineSpeakerDiarizationDestroyResult")]
    internal static extern void SpeakerDiarizationDestroyResult(IntPtr result);
}
