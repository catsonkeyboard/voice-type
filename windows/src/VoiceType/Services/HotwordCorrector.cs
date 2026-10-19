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
/// 识别结果后处理热词纠正（v7 三态条目，与 macOS HotwordCorrector.swift 对齐）。
/// <list type="bullet">
/// <item>纯 CJK：滑窗拼音编辑距离 ≤ ⌈拼音长度×20%⌉（v1 行为不变）</item>
/// <item>含拉丁：词段归一化匹配（精确→规范大小写归位；长度≥6 允许 20% 模糊，拒绝前缀命中）</item>
/// <item>混合（拉丁+CJK，如「Vue 组件」）：两段分别匹配组合命中</item>
/// <item>别名（「目标|别名」）：别名命中后整段替换为目标</item>
/// </list>
/// </summary>
public sealed class HotwordCorrector
{
    private abstract record Entry
    {
        public record Cjk(char[] Target, string Pinyin) : Entry;
        public record Latin(string Target, string Normalized, bool Fuzzy) : Entry;
        public record Mixed(
            string Target, string LatinNorm, bool LatinFuzzy,
            char[] Cjk, string CjkPinyin, bool LatinFirst) : Entry;
        public record Alias(string Target, Entry AliasEntry) : Entry;
    }

    private readonly List<Entry> _entries;
    private readonly IPinyinProvider _pinyin;

    public HotwordCorrector(IEnumerable<string> hotwords)
        : this(hotwords, new TinyPinyinProvider()) { }

    public HotwordCorrector(IEnumerable<string> hotwords, IPinyinProvider pinyin)
    {
        _pinyin = pinyin;
        _entries = hotwords
            .Select(w => w.Trim())
            .Where(w => w.Length > 0)
            .Select(Parse)
            .Where(e => e != null)
            .Cast<Entry>()
            .ToList();
    }

    public static bool IsCjk(char c) => c is >= '\u4E00' and <= '\u9FFF';

    private static bool IsAsciiLetter(char c) => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z';

    private static bool IsAsciiLetterOrDigit(char c) =>
        char.IsAsciiLetterOrDigit(c);

    private Entry? Parse(string raw)
    {
        // 别名语法：仅按第一个「|」分割；别名不可级联
        int pipe = raw.IndexOf('|');
        if (pipe >= 0)
        {
            string target = raw[..pipe].Trim();
            string aliasRaw = raw[(pipe + 1)..].Trim();
            if (target.Length == 0 || aliasRaw.Length == 0)
                return null;
            var aliasEntry = Parse(aliasRaw);
            if (aliasEntry is null or Entry.Alias)
                return null;
            return new Entry.Alias(target, aliasEntry);
        }

        bool hasAscii = raw.Any(IsAsciiLetter);
        bool hasCjk = raw.Any(IsCjk);
        if (hasAscii && hasCjk)
            return ParseMixed(raw);
        if (hasAscii)
        {
            string normalized = Normalize(raw);
            if (normalized.Length == 0) return null;
            return new Entry.Latin(raw, normalized, normalized.Length >= 6);
        }
        if (raw.All(IsCjk))
        {
            string py = _pinyin.Pinyin(raw);
            if (py.Length == 0) return null;
            return new Entry.Cjk(raw.ToCharArray(), py);
        }
        return null;
    }

    /// <summary>混合条目：只支持单次拉丁↔CJK 切换；多段切换返回 null。</summary>
    private Entry? ParseMixed(string raw)
    {
        var parts = new List<(bool Latin, string Text)>();
        foreach (var c in raw)
        {
            bool latin = IsAsciiLetter(c);
            bool cjk = IsCjk(c);
            if (!latin && !cjk && !char.IsWhiteSpace(c))
                return null;
            if (parts.Count > 0 && parts[^1].Latin == latin)
                parts[^1] = (latin, parts[^1].Text + c);
            else
                parts.Add((latin, c.ToString()));
        }
        var solid = parts.Where(p => p.Text.Trim().Length > 0).ToList();
        if (solid.Count != 2 || solid[0].Latin == solid[1].Latin)
            return null;
        string latinPart = solid.First(p => p.Latin).Text.Trim();
        string cjkPart = solid.First(p => !p.Latin).Text.Trim();
        if (!cjkPart.All(IsCjk))
            return null;
        string latinNorm = Normalize(latinPart);
        string cjkPy = _pinyin.Pinyin(cjkPart);
        if (latinNorm.Length == 0 || cjkPy.Length == 0)
            return null;
        return new Entry.Mixed(
            raw, latinNorm, latinNorm.Length >= 6,
            cjkPart.ToCharArray(), cjkPy, solid[0].Latin);
    }

    /// <summary>拉丁归一化：小写 + 去首尾非字母数字。</summary>
    private static string Normalize(string s)
    {
        string lower = s.ToLowerInvariant();
        int start = 0, end = lower.Length;
        while (start < end && !IsAsciiLetterOrDigit(lower[start])) start++;
        while (end > start && !IsAsciiLetterOrDigit(lower[end - 1])) end--;
        return lower[start..end];
    }

    /// <summary>拉丁词段字符：ASCII 字母/数字 + 内部分隔符（- . /）。空格不是内部字符。</summary>
    private static bool IsLatinWordChar(char c) =>
        char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '/';

    public string Correct(string text)
    {
        if (_entries.Count == 0)
            return text;
        char[] chars = text.ToCharArray();
        int i = 0;
        while (i < chars.Length)
        {
            bool consumed = false;
            foreach (var entry in _entries)
            {
                int? width = Match(entry, chars, i, replaceExact: false);
                if (width is int w)
                {
                    string replacementStr = TargetOf(entry);
                    // CJK 窗口被替换为含拉丁的文本时两侧按需补空格
                    bool windowIsCjk = true;
                    for (int k = i; k < i + w; k++)
                        if (!IsCjk(chars[k])) { windowIsCjk = false; break; }
                    bool replHasLatin = replacementStr.Any(IsAsciiLetter);
                    if (windowIsCjk && replHasLatin)
                    {
                        if (i > 0 && (IsCjk(chars[i - 1]) || char.IsAsciiDigit(chars[i - 1])))
                            replacementStr = " " + replacementStr;
                        int endIdx = i + w;
                        if (endIdx < chars.Length &&
                            (IsCjk(chars[endIdx]) || char.IsAsciiDigit(chars[endIdx])))
                            replacementStr += " ";
                    }
                    char[] replacement = replacementStr.ToCharArray();
                    char[] result = new char[chars.Length - w + replacement.Length];
                    Array.Copy(chars, 0, result, 0, i);
                    Array.Copy(replacement, 0, result, i, replacement.Length);
                    Array.Copy(chars, i + w, result, i + replacement.Length, chars.Length - i - w);
                    chars = result;
                    i += replacement.Length;
                    consumed = true;
                    break;
                }
            }
            if (!consumed)
                i += 1;
        }
        return new string(chars);
    }

    /// <summary>命中返回被替换窗口宽度；别名场景 replaceExact=true（精确命中正是要替换的）。</summary>
    private int? Match(Entry entry, char[] chars, int i, bool replaceExact)
    {
        switch (entry)
        {
            case Entry.Cjk cjk:
            {
                int n = cjk.Target.Length;
                if (i + n > chars.Length) return null;
                var window = new char[n];
                Array.Copy(chars, i, window, 0, n);
                if (window.SequenceEqual(cjk.Target))
                    return replaceExact ? n : null;
                if (!Array.TrueForAll(window, IsCjk)) return null;
                int maxDistance = Math.Max(1, (int)Math.Ceiling(cjk.Pinyin.Length * 0.2));
                return Levenshtein(cjk.Pinyin, PinyinOf(window)) <= maxDistance ? n : null;
            }
            case Entry.Latin latin:
                return MatchLatinWord(latin.Normalized, latin.Fuzzy, chars, i);
            case Entry.Mixed mixed:
            {
                if (mixed.LatinFirst)
                {
                    if (MatchLatinWord(mixed.LatinNorm, mixed.LatinFuzzy, chars, i) is not int w1)
                        return null;
                    int? after = SkipSpaces(chars, i + w1);
                    if (after is null ||
                        MatchCjkWindow(mixed.Cjk, mixed.CjkPinyin, chars, after.Value) is not int w2)
                        return null;
                    return after.Value + w2 - i;
                }
                if (MatchCjkWindow(mixed.Cjk, mixed.CjkPinyin, chars, i) is not int w3)
                    return null;
                int? after2 = SkipSpaces(chars, i + w3);
                if (after2 is null ||
                    MatchLatinWord(mixed.LatinNorm, mixed.LatinFuzzy, chars, after2.Value) is not int w4)
                    return null;
                return after2.Value + w4 - i;
            }
            case Entry.Alias alias:
                return Match(alias.AliasEntry, chars, i, replaceExact: true);
            default:
                return null;
        }
    }

    private static string TargetOf(Entry entry) => entry switch
    {
        Entry.Cjk c => new string(c.Target),
        Entry.Latin l => l.Target,
        Entry.Mixed m => m.Target,
        Entry.Alias a => a.Target,
        _ => "",
    };

    /// <summary>
    /// 拉丁词段匹配。误替换防护：距离 &gt;0 时拒绝严格前缀关系
    /// （「graph」是「graphql」前缀 = ASR 拆词特征，不替换）。
    /// </summary>
    private static int? MatchLatinWord(string normalized, bool fuzzy, char[] chars, int i)
    {
        if (LatinSegment(chars, i) is not (var segment, var width))
            return null;
        string segNorm = Normalize(new string(segment));
        if (segNorm.Length == 0) return null;
        if (segNorm == normalized) return width;
        if (!fuzzy) return null;
        int maxDistance = Math.Max(1, (int)Math.Ceiling(normalized.Length * 0.2));
        if (Levenshtein(normalized, segNorm) > maxDistance) return null;
        if (normalized.StartsWith(segNorm, StringComparison.Ordinal) ||
            segNorm.StartsWith(normalized, StringComparison.Ordinal))
            return null;
        return width;
    }

    private static int? MatchCjkWindow(char[] target, string targetPinyin, char[] chars, int i)
    {
        int n = target.Length;
        if (i + n > chars.Length) return null;
        var window = new char[n];
        Array.Copy(chars, i, window, 0, n);
        if (!Array.TrueForAll(window, IsCjk)) return null;
        // 注意：C# 版 PinyinOf 是实例方法（依赖注入的 provider），这里由调用方转换
        int maxDistance = Math.Max(1, (int)Math.Ceiling(targetPinyin.Length * 0.2));
        return CjkWindowPinyinCache(targetPinyin, window, chars, i) is string windowPinyin &&
            Levenshtein(targetPinyin, windowPinyin) <= maxDistance ? n : null;
    }

    // 避免 MatchCjkWindow 静态方法里调用实例 PinyinOf 的桥：把拼音计算折回实例路径
    private string? CjkWindowPinyinCache(string targetPinyin, char[] window, char[] chars, int i)
        => _pinyin.Pinyin(new string(window));

    private static int? SkipSpaces(char[] chars, int from)
    {
        if (from > chars.Length) return null;
        int j = from;
        while (j < chars.Length && chars[j] == ' ') j++;
        return j;
    }

    /// <summary>游标 i 必须落在 ASCII 字母/数字上；扩展到段尾并剔除尾随分隔符。</summary>
    private static (char[] Segment, int Width)? LatinSegment(char[] chars, int i)
    {
        if (i >= chars.Length || !char.IsAsciiLetterOrDigit(chars[i]))
            return null;
        int j = i + 1;
        while (j < chars.Length && IsLatinWordChar(chars[j])) j++;
        int end = j;
        while (end > i + 1 && (chars[end - 1] == '-' || chars[end - 1] == '.' || chars[end - 1] == '/'))
            end--;
        var segment = new char[end - i];
        Array.Copy(chars, i, segment, 0, end - i);
        return (segment, end - i);
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
