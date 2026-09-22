using System.Text.Json;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class DashScopeAsrProtocolTests
{
    // ----- 消息构造 -----

    [Fact]
    public void RunTaskMessage_HasExpectedFields()
    {
        string json = DashScopeAsr.RunTaskMessage("abc123", "fun-asr-realtime");
        using JsonDocument doc = JsonDocument.Parse(json);
        JsonElement root = doc.RootElement;
        JsonElement header = root.GetProperty("header");
        Assert.Equal("run-task", header.GetProperty("action").GetString());
        Assert.Equal("abc123", header.GetProperty("task_id").GetString());
        Assert.Equal("duplex", header.GetProperty("streaming").GetString());
        JsonElement payload = root.GetProperty("payload");
        Assert.Equal("audio", payload.GetProperty("task_group").GetString());
        Assert.Equal("asr", payload.GetProperty("task").GetString());
        Assert.Equal("recognition", payload.GetProperty("function").GetString());
        Assert.Equal("fun-asr-realtime", payload.GetProperty("model").GetString());
        JsonElement parameters = payload.GetProperty("parameters");
        Assert.Equal("pcm", parameters.GetProperty("format").GetString());
        Assert.Equal(16000, parameters.GetProperty("sample_rate").GetInt32());
        Assert.Equal(JsonValueKind.Object, payload.GetProperty("input").ValueKind);
    }

    [Fact]
    public void FinishTaskMessage_HasExpectedFields()
    {
        string json = DashScopeAsr.FinishTaskMessage("abc123");
        using JsonDocument doc = JsonDocument.Parse(json);
        JsonElement header = doc.RootElement.GetProperty("header");
        Assert.Equal("finish-task", header.GetProperty("action").GetString());
        Assert.Equal("abc123", header.GetProperty("task_id").GetString());
    }

    [Fact]
    public void NewTaskId_Is32HexNoDash()
    {
        string id = DashScopeAsr.NewTaskId();
        Assert.Equal(32, id.Length);
        Assert.DoesNotContain("-", id);
    }

    // ----- 事件解析 -----

    [Fact]
    public void ParseEvent_TaskStarted()
    {
        var evt = DashScopeAsr.ParseEvent(
            """{"header":{"event":"task-started","task_id":"x","attributes":{}},"payload":{}}""");
        Assert.Equal(DashScopeAsr.ServerEventKind.TaskStarted, evt.Kind);
    }

    [Fact]
    public void ParseEvent_ResultGeneratedPartial()
    {
        string json = """
            {"header":{"event":"result-generated","task_id":"x"},
             "payload":{"output":{"sentence":{"begin_time":170,"end_time":null,"text":"明天上","sentence_end":false}},"usage":null}}
            """;
        var evt = DashScopeAsr.ParseEvent(json);
        Assert.Equal(DashScopeAsr.ServerEventKind.ResultGenerated, evt.Kind);
        Assert.Equal("明天上", evt.Sentence.Text);
        Assert.False(evt.Sentence.SentenceEnd);
    }

    [Fact]
    public void ParseEvent_ResultGeneratedFinal()
    {
        string json = """
            {"header":{"event":"result-generated","task_id":"x"},
             "payload":{"output":{"sentence":{"begin_time":170,"end_time":2100,"text":"明天上午九点开会。","sentence_end":true}}}}
            """;
        var evt = DashScopeAsr.ParseEvent(json);
        Assert.Equal(DashScopeAsr.ServerEventKind.ResultGenerated, evt.Kind);
        Assert.True(evt.Sentence.SentenceEnd);
    }

    [Fact]
    public void ParseEvent_TaskFinishedAndFailed()
    {
        Assert.Equal(DashScopeAsr.ServerEventKind.TaskFinished, DashScopeAsr.ParseEvent(
            """{"header":{"event":"task-finished","task_id":"x"},"payload":{"output":{}}}""").Kind);
        var failed = DashScopeAsr.ParseEvent(
            """{"header":{"event":"task-failed","task_id":"x","error_code":"InvalidApiKey","error_message":"Invalid API-key provided."},"payload":{}}""");
        Assert.Equal(DashScopeAsr.ServerEventKind.TaskFailed, failed.Kind);
        Assert.Equal("InvalidApiKey", failed.Code);
        Assert.Equal("Invalid API-key provided.", failed.Message);
    }

    [Fact]
    public void ParseEvent_GarbageReturnsUnknown()
    {
        Assert.Equal(DashScopeAsr.ServerEventKind.Unknown, DashScopeAsr.ParseEvent("not json").Kind);
        Assert.Equal(DashScopeAsr.ServerEventKind.Unknown, DashScopeAsr.ParseEvent("""{"header":{}}""").Kind);
    }

    // ----- PCM16 -----

    [Fact]
    public void Pcm16_Conversion()
    {
        byte[] data = DashScopeAsr.Pcm16Data([0f, 1f, -1f, 0.5f, 2f]);
        Assert.Equal(10, data.Length);
        short[] values = new short[5];
        System.Buffer.BlockCopy(data, 0, values, 0, data.Length);
        Assert.Equal(0, values[0]);
        Assert.Equal(32767, values[1]);
        Assert.Equal(-32767, values[2]);
        Assert.Equal(16383, values[3]);
        Assert.Equal(32767, values[4]);  // 超界截断
    }

    // ----- 句子装配 -----

    [Fact]
    public void Assembler_PartialThenFinal()
    {
        var a = new SentenceAssembler();
        a.Ingest(new DashScopeAsr.Sentence("明天", false));
        Assert.Equal("明天", a.LiveText);
        a.Ingest(new DashScopeAsr.Sentence("明天上午", false));
        Assert.Equal("明天上午", a.LiveText);
        a.Ingest(new DashScopeAsr.Sentence("明天上午九点开会。", true));
        a.Ingest(new DashScopeAsr.Sentence("记得带电脑", false));
        Assert.Equal("明天上午九点开会。记得带电脑", a.LiveText);
        Assert.Equal("明天上午九点开会。记得带电脑", a.FinalText);  // 残留 partial 并入终稿
    }

    [Fact]
    public void Assembler_Empty()
    {
        var a = new SentenceAssembler();
        Assert.Equal("", a.LiveText);
        Assert.Equal("", a.FinalText);
    }
}
