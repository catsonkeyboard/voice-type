namespace VoiceType.Models;

/// <summary>说话人分离后的一段（秒）。</summary>
public sealed class SpeakerSegment
{
    public int Speaker { get; set; }
    public double Start { get; set; }
    public double End { get; set; }
    public string Text { get; set; } = "";
}
