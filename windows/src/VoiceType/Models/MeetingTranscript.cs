using System.Text.Json;
using System.Text.Json.Serialization;
using VoiceType.Services;

namespace VoiceType.Models;

/// <summary>一场会议的转写产物：与音频同名的 JSON 存于 meetings 目录（与 macOS 端结构兼容）。</summary>
public sealed class MeetingTranscript
{
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; }
    [JsonPropertyName("duration")] public double Duration { get; set; }
    [JsonPropertyName("audioFile")] public string AudioFile { get; set; } = "";
    [JsonPropertyName("segments")] public List<SpeakerSegment> Segments { get; set; } = [];
    [JsonPropertyName("speakerNames")]
    public Dictionary<int, string> SpeakerNames { get; set; } = [];
    /// <summary>分离失败降级为整段转写</summary>
    [JsonPropertyName("degraded")] public bool Degraded { get; set; }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
    };

    public static string MeetingsDir =>
        Path.Combine(ModelPaths.AppDataRoot, "meetings");

    [JsonIgnore]
    public List<int> SpeakerIds => Segments.Select(s => s.Speaker).Distinct().OrderBy(x => x).ToList();

    public string DisplayName(int speaker) =>
        SpeakerNames.TryGetValue(speaker, out string? name) && name.Length > 0
            ? name
            : $"说话人{speaker + 1}";

    public static string Timestamp(double seconds)
    {
        int s = (int)seconds;
        return $"{s / 60:D2}:{s % 60:D2}";
    }

    public string Markdown()
    {
        var lines = new List<string>
        {
            $"# 会议转写 {CreatedAt:yyyy-MM-dd HH:mm}", "",
        };
        if (Degraded)
        {
            lines.Add("> 说话人分离不可用，本稿为整段转写");
            lines.Add("");
        }
        foreach (SpeakerSegment seg in Segments.Where(s => s.Text.Length > 0))
        {
            lines.Add($"**{DisplayName(seg.Speaker)} [{Timestamp(seg.Start)}]** {seg.Text}");
            lines.Add("");
        }
        return string.Join("\n", lines);
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, JsonOpts));
    }

    public static MeetingTranscript? Load(string path)
    {
        try
        {
            return JsonSerializer.Deserialize<MeetingTranscript>(File.ReadAllText(path), JsonOpts);
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>会议纪要 prompt（走 PolishService 的通用补全通道）。</summary>
public static class MinutesPrompt
{
    public const string System =
        """
        你是会议纪要撰写助手。根据用户提供的带说话人标注的会议转写稿，输出结构化的中文会议纪要，包含以下小节（无相关内容的小节写"无"）：
        ## 会议主题
        ## 讨论要点
        ## 决议
        ## 待办事项
        要求：忠于原文，不编造；待办事项尽量标注负责人（依据说话人）；只输出纪要本身，不要解释。
        """;

    public static string User(MeetingTranscript transcript) => transcript.Markdown();
}
