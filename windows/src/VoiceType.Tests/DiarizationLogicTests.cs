using VoiceType.Models;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class DiarizationLogicTests
{
    private static SpeakerSegment Seg(int speaker, double start, double end) =>
        new() { Speaker = speaker, Start = start, End = end };

    [Fact]
    public void MergeAdjacent_MergesSameSpeakerWithinGap()
    {
        var segments = new List<SpeakerSegment>
        {
            Seg(0, 0, 1.0),
            Seg(0, 1.4, 2.0),   // 间隔 0.4 ≤ 1.0，合并
            Seg(1, 2.5, 3.0),   // 换人，保留
            Seg(0, 4.0, 5.0),
        };
        List<SpeakerSegment> merged = DiarizationService.MergeAdjacent(segments);
        Assert.Equal(3, merged.Count);
        Assert.Equal((0, 0.0, 2.0), (merged[0].Speaker, merged[0].Start, merged[0].End));
        Assert.Equal((1, 2.5, 3.0), (merged[1].Speaker, merged[1].Start, merged[1].End));
        Assert.Equal((0, 4.0, 5.0), (merged[2].Speaker, merged[2].Start, merged[2].End));
    }

    [Fact]
    public void MergeAdjacent_KeepsGapBeyondThreshold()
    {
        var segments = new List<SpeakerSegment>
        {
            Seg(0, 0, 1.0),
            Seg(0, 2.5, 3.0),   // 间隔 1.5 > 1.0，保留
        };
        Assert.Equal(2, DiarizationService.MergeAdjacent(segments).Count);
    }

    [Fact]
    public void MergeAdjacent_SortsByStart()
    {
        var segments = new List<SpeakerSegment>
        {
            Seg(1, 5.0, 6.0),
            Seg(0, 0.0, 1.0),
            Seg(0, 1.2, 2.0),
        };
        List<SpeakerSegment> merged = DiarizationService.MergeAdjacent(segments);
        Assert.Equal(2, merged.Count);
        Assert.Equal(0, merged[0].Speaker);
        Assert.Equal(0.0, merged[0].Start);
        Assert.Equal(2.0, merged[0].End);
    }

    [Fact]
    public void MergeAdjacent_Empty()
    {
        Assert.Empty(DiarizationService.MergeAdjacent([]));
    }
}

public class MeetingTranscriptTests
{
    [Fact]
    public void Timestamp_Format()
    {
        Assert.Equal("00:00", MeetingTranscript.Timestamp(0));
        Assert.Equal("00:59", MeetingTranscript.Timestamp(59.9));
        Assert.Equal("01:00", MeetingTranscript.Timestamp(60));
        Assert.Equal("12:34", MeetingTranscript.Timestamp(754));
    }

    [Fact]
    public void Markdown_ContainsSpeakerAndText()
    {
        var t = new MeetingTranscript
        {
            CreatedAt = new DateTime(2026, 7, 1, 10, 30, 0),
            Duration = 60,
            Segments =
            [
                new SpeakerSegment { Speaker = 0, Start = 0, End = 10, Text = "大家好" },
                new SpeakerSegment { Speaker = 1, Start = 12, End = 20, Text = "开始吧" },
            ],
        };
        string md = t.Markdown();
        Assert.Contains("**说话人1 [00:00]** 大家好", md);
        Assert.Contains("**说话人2 [00:12]** 开始吧", md);
        t.SpeakerNames[1] = "老王";
        Assert.Contains("**老王 [00:12]** 开始吧", t.Markdown());
    }

    [Fact]
    public void SaveLoad_RoundTrip()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-test-{Guid.NewGuid():N}.json");
        try
        {
            var t = new MeetingTranscript
            {
                CreatedAt = DateTime.Now,
                Duration = 42,
                AudioFile = "a.wav",
                Segments = [new SpeakerSegment { Speaker = 0, Start = 0, End = 5, Text = "x" }],
                SpeakerNames = new Dictionary<int, string> { [0] = "张三" },
                Degraded = true,
            };
            t.Save(path);
            MeetingTranscript? loaded = MeetingTranscript.Load(path);
            Assert.NotNull(loaded);
            Assert.Equal("a.wav", loaded.AudioFile);
            Assert.Equal(42, loaded.Duration);
            Assert.True(loaded.Degraded);
            Assert.Equal("张三", loaded.DisplayName(0));
            Assert.Single(loaded.Segments);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Load_Corrupt_ReturnsNull()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-test-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "{not json");
        try
        {
            Assert.Null(MeetingTranscript.Load(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
