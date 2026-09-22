using System.Text.Json.Serialization;

namespace VoiceType.Models;

/// <summary>一条转写历史（对应 macOS TranscriptRecord @Model）。</summary>
public sealed class TranscriptRecord
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.Now;
    [JsonPropertyName("durationSeconds")] public double DurationSeconds { get; set; }
    /// <summary>"dictation" | "file"</summary>
    [JsonPropertyName("source")] public string Source { get; set; } = "dictation";
    /// <summary>润色前原始转写；未润色为 null</summary>
    [JsonPropertyName("rawText")] public string? RawText { get; set; }
}
