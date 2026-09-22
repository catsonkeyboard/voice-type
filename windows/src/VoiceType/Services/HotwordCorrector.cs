namespace VoiceType.Services;

/// <summary>
/// 汉字 → 无声调小写拼音（对应 macOS CFStringTransform MandarinLatin + StripDiacritics）。
/// 实现用 TinyPinyin.Net；抽象成接口便于替换与单测注入。
/// </summary>
public interface IPinyinProvider
{
    /// <summary>非汉字字符原样保留（与 CFStringTransform 行为一致，随后统一小写、去空白）。</summary>
    string Pinyin(string text);
}

public sealed class TinyPinyinProvider : IPinyinProvider
{
    public string Pinyin(string text) =>
        TinyPinyin.PinyinHelper.GetPinyin(text, "").ToLowerInvariant().Replace(" ", "");
}

/// <summary>
/// 识别结果后处理热词纠正：对文本按热词字数开滑窗，
/// 窗口拼音与热词拼音编辑距离 ≤ ⌈拼音长度×20%⌉（至少 1）即替换。
/// 仅处理 CJK 字符窗口（拼音方案对英文无意义）。
/// </summary>
public sealed class HotwordCorrector
{
    private readonly List<(char[] Chars, string Pinyin)> _entries;
    private readonly IPinyinProvider _pinyin;

    public HotwordCorrector(IEnumerable<string> hotwords)
        : this(hotwords, new TinyPinyinProvider()) { }

    public HotwordCorrector(IEnumerable<string> hotwords, IPinyinProvider pinyin)
    {
        _pinyin = pinyin;
        _entries = hotwords
            .Select(w => w.Trim())
            .Where(w => w.Length > 0 && w.All(IsCjk))
            .Select(w => (w.ToCharArray(), pinyin.Pinyin(w)))
            .Where(e => e.Item2.Length > 0)
            .ToList();
    }

    public static bool IsCjk(char c) => c is >= '\u4E00' and <= '\u9FFF';

    public string Correct(string text)
    {
        if (_entries.Count == 0)
            return text;
        char[] chars = text.ToCharArray();
        foreach ((char[] target, string targetPinyin) in _entries)
        {
            int n = target.Length;
            if (chars.Length < n)
                continue;
            int maxDistance = Math.Max(1, (int)Math.Ceiling(targetPinyin.Length * 0.2));
            int i = 0;
            while (i + n <= chars.Length)
            {
                var window = new char[n];
                Array.Copy(chars, i, window, 0, n);
                if (window.SequenceEqual(target))
                {
                    i += n;
                    continue;
                }
                if (!Array.TrueForAll(window, IsCjk))
                {
                    i += 1;
                    continue;
                }
                string windowPinyin = PinyinOf(window);
                if (Levenshtein(targetPinyin, windowPinyin) <= maxDistance)
                {
                    Array.Copy(target, 0, chars, i, n);
                    i += n;
                }
                else
                {
                    i += 1;
                }
            }
        }
        return new string(chars);
    }

    private string PinyinOf(char[] window) => _pinyin.Pinyin(new string(window));

    public static int Levenshtein(ReadOnlySpan<char> a, ReadOnlySpan<char> b)
    {
        if (a.IsEmpty) return b.Length;
        if (b.IsEmpty) return a.Length;
        int[] prev = Enumerable.Range(0, b.Length + 1).ToArray();
        var curr = new int[b.Length + 1];
        for (int i = 1; i <= a.Length; i++)
        {
            curr[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                curr[j] = Math.Min(Math.Min(prev[j] + 1, curr[j - 1] + 1), prev[j - 1] + cost);
            }
            (prev, curr) = (curr, prev);
        }
        return prev[b.Length];
    }
}
