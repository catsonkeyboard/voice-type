using System.Runtime.InteropServices;

namespace VoiceType.Interop.SherpaOnnx;

internal readonly record struct DiarizationSegment(float Start, float End, int Speaker);

/// <summary>离线说话人分离安全包装（pyannote 分段 + 3D-Speaker 声纹聚类）。</summary>
internal sealed class OfflineSpeakerDiarization : IDisposable
{
    private IntPtr _sd;

    private OfflineSpeakerDiarization(IntPtr sd) => _sd = sd;

    public static OfflineSpeakerDiarization Create(DiarizationOptions o)
    {
        using var pool = new NativeStringPool();
        var config = new SherpaOnnxNative.OfflineSpeakerDiarizationConfig
        {
            segmentation = new SherpaOnnxNative.OfflineSpeakerSegmentationModelConfig
            {
                pyannote = new SherpaOnnxNative.OfflineSpeakerSegmentationPyannoteModelConfig
                {
                    model = pool.Alloc(o.SegmentationModel),
                },
                num_threads = o.SegmentationNumThreads,
                provider = pool.Alloc("cpu"),
            },
            embedding = new SherpaOnnxNative.SpeakerEmbeddingExtractorConfig
            {
                model = pool.Alloc(o.EmbeddingModel),
                num_threads = o.EmbeddingNumThreads,
                provider = pool.Alloc("cpu"),
            },
            clustering = new SherpaOnnxNative.FastClusteringConfig
            {
                num_clusters = o.NumClusters ?? -1,
                threshold = 0.5f,
            },
            min_duration_on = 0.3f,
            min_duration_off = 0.5f,
        };
        IntPtr p = SherpaOnnxNative.CreateOfflineSpeakerDiarization(ref config);
        if (p == IntPtr.Zero)
            throw new InvalidOperationException(
                "sherpa-onnx 创建说话人分离器失败（segmentation.onnx / speaker-embedding.onnx 缺失？）");
        return new OfflineSpeakerDiarization(p);
    }

    public int SampleRate => SherpaOnnxNative.SpeakerDiarizationGetSampleRate(_sd);

    /// <summary>整段音频分离，按开始时间排序返回。</summary>
    public List<DiarizationSegment> Process(float[] samples)
    {
        ObjectDisposedException.ThrowIf(_sd == IntPtr.Zero, this);
        IntPtr result = SherpaOnnxNative.SpeakerDiarizationProcess(_sd, samples, samples.Length);
        if (result == IntPtr.Zero)
            return [];
        IntPtr segs = IntPtr.Zero;
        try
        {
            int n = SherpaOnnxNative.SpeakerDiarizationResultGetNumSegments(result);
            segs = SherpaOnnxNative.SpeakerDiarizationResultSortByStartTime(result);
            if (segs == IntPtr.Zero || n == 0)
                return [];
            int size = Marshal.SizeOf<SherpaOnnxNative.OfflineSpeakerDiarizationSegment>();
            var list = new List<DiarizationSegment>(n);
            for (int i = 0; i < n; i++)
            {
                var s = Marshal.PtrToStructure<SherpaOnnxNative.OfflineSpeakerDiarizationSegment>(
                    segs + i * size);
                list.Add(new DiarizationSegment(s.start, s.end, s.speaker));
            }
            return list;
        }
        finally
        {
            if (segs != IntPtr.Zero)
                SherpaOnnxNative.SpeakerDiarizationDestroySegment(segs);
            SherpaOnnxNative.SpeakerDiarizationDestroyResult(result);
        }
    }

    public void Dispose()
    {
        if (_sd != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyOfflineSpeakerDiarization(_sd);
            _sd = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    ~OfflineSpeakerDiarization() => Dispose();
}

internal sealed class DiarizationOptions
{
    public string SegmentationModel { get; init; } = "";
    public string EmbeddingModel { get; init; } = "";
    public int SegmentationNumThreads { get; init; } = 2;
    public int EmbeddingNumThreads { get; init; } = 2;
    /// <summary>null = 自动估计人数</summary>
    public int? NumClusters { get; init; }
}
