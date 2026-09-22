using VoiceType.Models;

namespace VoiceType.Services;

/// <summary>
/// 会议处理编排：解码 → 说话人分离 → 段合并 → 逐段转写 → 落盘 JSON。
/// 分离失败自动降级为整段转写（Degraded 标记）。
/// </summary>
public sealed class MeetingProcessor : IDisposable
{
    private readonly AsrService _asr;
    private readonly DiarizationService _diarization = new();

    public MeetingProcessor(AsrService asr) => _asr = asr;

    /// <summary>进度回调（stage, 0~1），在后台线程调用；UI 侧自行派发。</summary>
    public async Task<(MeetingTranscript Transcript, string JsonPath)> ProcessAsync(
        string audioPath, int? numSpeakers,
        Action<string, double> onProgress, CancellationToken ct = default)
    {
        onProgress("解码音频…", 0);
        float[] samples = AudioFileDecoder.Decode16kMono(audioPath);
        double duration = samples.Length / 16000.0;

        var segments = new List<SpeakerSegment>();
        bool degraded = false;
        try
        {
            onProgress("说话人分离…", 0.1);
            List<SpeakerSegment> raw =
                await _diarization.DiarizeAsync(samples, numSpeakers, ct);
            segments = DiarizationService.MergeAdjacent(raw);
            if (segments.Count == 0)
                degraded = true;
        }
        catch
        {
            degraded = true;
        }

        if (degraded)
        {
            string text = await _asr.TranscribeFileAsync(audioPath, p =>
                onProgress("整段转写中…", 0.3 + p * 0.65), ct);
            segments = [new SpeakerSegment { Speaker = 0, Start = 0, End = duration, Text = text }];
        }
        else
        {
            for (int i = 0; i < segments.Count; i++)
            {
                onProgress($"转写 {i + 1}/{segments.Count} 段…",
                    0.2 + 0.75 * i / Math.Max(segments.Count, 1));
                int lo = Math.Max(0, (int)(segments[i].Start * 16000));
                int hi = Math.Min(samples.Length, (int)(segments[i].End * 16000));
                if (hi <= lo)
                    continue;
                try
                {
                    segments[i].Text = await _asr.TranscribeAsync(samples[lo..hi], ct: ct);
                }
                catch
                {
                    segments[i].Text = "";
                }
            }
            segments.RemoveAll(s => s.Text.Length == 0);
        }

        onProgress("保存…", 0.98);
        var transcript = new MeetingTranscript
        {
            CreatedAt = DateTime.Now,
            Duration = duration,
            AudioFile = Path.GetFileName(audioPath),
            Segments = segments,
            SpeakerNames = [],
            Degraded = degraded,
        };
        string jsonName = Path.GetFileNameWithoutExtension(audioPath) + ".json";
        string jsonPath = Path.Combine(MeetingTranscript.MeetingsDir, jsonName);
        transcript.Save(jsonPath);
        return (transcript, jsonPath);
    }

    public void Dispose() => _diarization.Dispose();
}
