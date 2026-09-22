using VoiceType.Interop.SherpaOnnx;
using VoiceType.Models;

namespace VoiceType.Services;

public sealed class DiarizationException : Exception
{
    public DiarizationException(string message) : base(message) { }
}

/// <summary>
/// 说话人分离：pyannote 分段 + 3D-Speaker 声纹聚类（sherpa-onnx，纯本地）。
/// 推理在串行信号量下执行，模型懒加载常驻。
/// </summary>
public sealed class DiarizationService : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private OfflineSpeakerDiarization? _wrapper;
    private int _loadedNumClusters = int.MinValue;

    /// <summary>numSpeakers 为 null 时自动估计人数。推理串行 + 线程池执行。</summary>
    public async Task<List<SpeakerSegment>> DiarizeAsync(
        float[] samples, int? numSpeakers, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            return await Task.Run(() => DiarizeSync(samples, numSpeakers), ct);
        }
        finally
        {
            _gate.Release();
        }
    }

    private List<SpeakerSegment> DiarizeSync(float[] samples, int? numSpeakers)
    {
        if (!ModelPaths.DiarizationPresent)
            throw new DiarizationException(
                "说话人分离模型未安装，请运行 windows/scripts/setup_diarization.ps1");
        int clusters = numSpeakers ?? -1;
        if (_wrapper is null || _loadedNumClusters != clusters)
        {
            _wrapper?.Dispose();
            _wrapper = OfflineSpeakerDiarization.Create(new DiarizationOptions
            {
                SegmentationModel = ModelPaths.SegmentationModel,
                EmbeddingModel = ModelPaths.SpeakerEmbeddingModel,
                SegmentationNumThreads = 2,
                EmbeddingNumThreads = 2,
                NumClusters = numSpeakers,
            });
            _loadedNumClusters = clusters;
        }
        return _wrapper.Process(samples)
            .Select(s => new SpeakerSegment { Speaker = s.Speaker, Start = s.Start, End = s.End })
            .ToList();
    }

    /// <summary>相邻同说话人且间隔 ≤ maxGap 秒的段合并（减少转写碎片）</summary>
    public static List<SpeakerSegment> MergeAdjacent(
        List<SpeakerSegment> segments, double maxGap = 1.0)
    {
        var result = new List<SpeakerSegment>();
        foreach (SpeakerSegment seg in segments.OrderBy(s => s.Start))
        {
            if (result.Count > 0 &&
                result[^1].Speaker == seg.Speaker &&
                seg.Start - result[^1].End <= maxGap)
            {
                result[^1].End = Math.Max(result[^1].End, seg.End);
            }
            else
            {
                result.Add(new SpeakerSegment
                {
                    Speaker = seg.Speaker, Start = seg.Start, End = seg.End, Text = seg.Text,
                });
            }
        }
        return result;
    }

    public void Dispose()
    {
        _wrapper?.Dispose();
        _wrapper = null;
        _gate.Dispose();
    }
}
