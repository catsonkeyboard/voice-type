using VoiceType.Models;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class HistoryStoreTests
{
    private static string TempPath() =>
        Path.Combine(Path.GetTempPath(), $"vt-history-{Guid.NewGuid():N}.json");

    [Fact]
    public void Add_ThenRecent_ReturnsNewestFirst()
    {
        var store = new HistoryStore(TempPath());
        store.Add("第一条", 1, "dictation");
        store.Add("第二条", 2, "dictation");
        List<TranscriptRecord> recent = store.Recent();
        Assert.Equal("第二条", recent[0].Text);
        Assert.Equal("第一条", recent[1].Text);
    }

    [Fact]
    public void Recent_RespectsLimit()
    {
        var store = new HistoryStore(TempPath());
        for (int i = 0; i < 10; i++)
            store.Add($"记录{i}", 0, "dictation");
        Assert.Equal(3, store.Recent(3).Count);
    }

    [Fact]
    public void Trim_KeepsMaxRecords()
    {
        var store = new HistoryStore(TempPath());
        for (int i = 0; i < HistoryStore.MaxRecords + 20; i++)
            store.Add($"记录{i}", 0, "dictation");
        Assert.Equal(HistoryStore.MaxRecords, store.Recent(int.MaxValue).Count);
    }

    [Fact]
    public void Delete_RemovesRecord()
    {
        var store = new HistoryStore(TempPath());
        store.Add("要删的", 0, "dictation");
        store.Add("留下的", 0, "dictation");
        TranscriptRecord target = store.Recent().Single(r => r.Text == "要删的");
        store.Delete(target.Id);
        Assert.Single(store.Recent());
        Assert.Equal("留下的", store.Recent()[0].Text);
    }

    [Fact]
    public void Clear_RemovesAll()
    {
        var store = new HistoryStore(TempPath());
        store.Add("a", 0, "dictation");
        store.Add("b", 0, "file");
        store.Clear();
        Assert.Empty(store.Recent());
    }

    [Fact]
    public void RawText_Persisted()
    {
        var store = new HistoryStore(TempPath());
        store.Add("润色后", 1, "dictation", rawText: "原文");
        TranscriptRecord record = store.Recent()[0];
        Assert.Equal("润色后", record.Text);
        Assert.Equal("原文", record.RawText);
    }

    [Fact]
    public void Persists_AcrossInstances()
    {
        string path = TempPath();
        var first = new HistoryStore(path);
        first.Add("跨实例", 0, "dictation");
        var reopened = new HistoryStore(path);
        Assert.Equal("跨实例", reopened.Recent()[0].Text);
    }
}
