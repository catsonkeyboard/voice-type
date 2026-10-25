using System.Text;

namespace VoiceType.Services;

/// <summary>
/// 识别结果的「重复折叠」。
///
/// 逐字生成的识别模型（Fun-ASR-Nano、Qwen3-ASR）和润色模型偶尔会陷入循环：
/// 在一处听不准的地方（如念出来的「⌥⌘V」）把同一小段反复输出到长度上限，
/// 2026-10-23 实测出现过上百个「CTRL、」。正常说话几乎不会把同一段连说 6 遍以上，
/// 所以这样的连续重复只留一份。
/// </summary>
public static class RepetitionGuard
{
    /// <summary>连续重复达到这个次数才算循环</summary>
    public const int MinRepeats = 6;
    /// <summary>只检查不超过这么长的重复单元</summary>
    public const int MaxUnitLength = 10;
    /// <summary>单个字的长串保留这么多个，「哈哈哈」这类不受影响</summary>
    public const int SingleCharacterKeep = 3;

    /// <summary>
    /// 纯函数：把连续重复 <see cref="MinRepeats"/> 次以上的片段折叠成一份（单个字留三个）。
    /// 纯数字不折叠，避免改坏「000000」这类验证码、号码。
    /// </summary>
    public static string Collapse(string text)
    {
        char[] chars = text.ToCharArray();
        var output = new StringBuilder(chars.Length);
        int i = 0;
        while (i < chars.Length)
        {
            bool collapsed = false;
            for (int length = 1; length <= MaxUnitLength && i + length * MinRepeats <= chars.Length;
                length++)
            {
                ReadOnlySpan<char> unit = chars.AsSpan(i, length);
                int count = 1;
                int next = i + length;
                while (next + length <= chars.Length
                    && chars.AsSpan(next, length).SequenceEqual(unit))
                {
                    count++;
                    next += length;
                }
                if (count < MinRepeats || AllDigits(unit))
                    continue;
                int keep = length == 1 ? SingleCharacterKeep : 1;
                for (int n = 0; n < keep; n++)
                    output.Append(unit);
                i = next;
                collapsed = true;
                break;
            }
            if (!collapsed)
            {
                output.Append(chars[i]);
                i++;
            }
        }
        return output.ToString();
    }

    private static bool AllDigits(ReadOnlySpan<char> unit)
    {
        foreach (char c in unit)
        {
            if (!char.IsNumber(c))
                return false;
        }
        return true;
    }
}
