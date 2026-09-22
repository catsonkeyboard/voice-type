using System.Buffers.Binary;
using System.Text.Json;

namespace VoiceType.Services;

/// <summary>
/// DashScope 实时 ASR WebSocket 协议的纯逻辑部分（无 I/O，可完整单测）。
/// 协议参考: https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api
/// </summary>
public static class DashScopeAsr
{
    public const string DefaultEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/";
    public const string DefaultModel = "fun-asr-realtime";

    public readonly record struct Sentence(string Text, bool SentenceEnd);

    public enum ServerEventKind
    {
        TaskStarted,
        ResultGenerated,
        TaskFinished,
        TaskFailed,
        Unknown,
    }

    public readonly record struct ServerEvent(ServerEventKind Kind, Sentence Sentence, string Code, string Message)
    {
        public static ServerEvent TaskStarted() => new(ServerEventKind.TaskStarted, default, "", "");
        public static ServerEvent TaskFinished() => new(ServerEventKind.TaskFinished, default, "", "");
        public static ServerEvent TaskFailed(string code, string message) =>
            new(ServerEventKind.TaskFailed, default, code, message);
        public static ServerEvent Result(Sentence s) => new(ServerEventKind.ResultGenerated, s, "", "");
        public static ServerEvent UnknownEvent() => new(ServerEventKind.Unknown, default, "", "");
    }

    public static string NewTaskId() =>
        Guid.NewGuid().ToString("N");

    public static string RunTaskMessage(string taskId, string model, int sampleRate = 16000)
    {
        var obj = new
        {
            header = new { action = "run-task", task_id = taskId, streaming = "duplex" },
            payload = new
            {
                task_group = "audio",
                task = "asr",
                function = "recognition",
                model,
                parameters = new { format = "pcm", sample_rate = sampleRate },
                input = new { },
            },
        };
        return JsonSerializer.Serialize(obj);
    }

    public static string FinishTaskMessage(string taskId)
    {
        var obj = new
        {
            header = new { action = "finish-task", task_id = taskId, streaming = "duplex" },
            payload = new { input = new { } },
        };
        return JsonSerializer.Serialize(obj);
    }

    public static ServerEvent ParseEvent(string text)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(text);
        }
        catch
        {
            return ServerEvent.UnknownEvent();
        }
        using (doc)
        {
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("header", out JsonElement header) ||
                header.ValueKind != JsonValueKind.Object ||
                !header.TryGetProperty("event", out JsonElement eventEl) ||
                eventEl.ValueKind != JsonValueKind.String)
                return ServerEvent.UnknownEvent();

            switch (eventEl.GetString())
            {
                case "task-started":
                    return ServerEvent.TaskStarted();
                case "task-finished":
                    return ServerEvent.TaskFinished();
                case "task-failed":
                    string code = header.TryGetProperty("error_code", out JsonElement c) &&
                                  c.ValueKind == JsonValueKind.String ? c.GetString() ?? "unknown" : "unknown";
                    string message = header.TryGetProperty("error_message", out JsonElement m) &&
                                     m.ValueKind == JsonValueKind.String ? m.GetString() ?? "未知错误" : "未知错误";
                    return ServerEvent.TaskFailed(code, message);
                case "result-generated":
                    if (root.TryGetProperty("payload", out JsonElement payload) &&
                        payload.ValueKind == JsonValueKind.Object &&
                        payload.TryGetProperty("output", out JsonElement output) &&
                        output.ValueKind == JsonValueKind.Object &&
                        output.TryGetProperty("sentence", out JsonElement sentence) &&
                        sentence.ValueKind == JsonValueKind.Object &&
                        sentence.TryGetProperty("text", out JsonElement textEl) &&
                        textEl.ValueKind == JsonValueKind.String)
                    {
                        bool sentenceEnd = sentence.TryGetProperty("sentence_end", out JsonElement se) &&
                                           se.ValueKind == JsonValueKind.True;
                        return ServerEvent.Result(new Sentence(textEl.GetString() ?? "", sentenceEnd));
                    }
                    return ServerEvent.UnknownEvent();
                default:
                    return ServerEvent.UnknownEvent();
            }
        }
    }

    /// <summary>Float32 [-1,1] → 16bit PCM 小端</summary>
    public static byte[] Pcm16Data(ReadOnlySpan<float> samples)
    {
        byte[] data = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
        {
            float clamped = Math.Clamp(samples[i], -1f, 1f);
            short value = (short)(clamped * 32767);
            BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(i * 2), value);
        }
        return data;
    }
}

/// <summary>增量识别结果装配：已定稿句子 + 当前 partial → 实时文本 / 终稿。</summary>
public sealed class SentenceAssembler
{
    private readonly List<string> _finalized = [];

    public string Partial { get; private set; } = "";

    public void Ingest(DashScopeAsr.Sentence sentence)
    {
        if (sentence.SentenceEnd)
        {
            if (sentence.Text.Length > 0)
                _finalized.Add(sentence.Text);
            Partial = "";
        }
        else
        {
            Partial = sentence.Text;
        }
    }

    public string LiveText =>
        string.Concat(string.Concat(_finalized), Partial);

    /// <summary>finish 时残留的 partial 并入终稿（服务端可能不给最后一句发 sentence_end）</summary>
    public string FinalText => LiveText;
}
