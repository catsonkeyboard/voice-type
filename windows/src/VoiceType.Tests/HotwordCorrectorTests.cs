using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

/// <summary>拼音假实现：仅覆盖测试用字（隔离对第三方库输出细节的依赖）。</summary>
sealed class FakePinyin : IPinyinProvider
{
    private readonly Dictionary<char, string> _map;

    public FakePinyin() : this([])
    {
    }

    public FakePinyin(Dictionary<char, string> map) => _map = map;

    public string Pinyin(string text) =>
        string.Concat(text.Select(c => _map.TryGetValue(c, out string? py) ? py : c.ToString()));
}

public class HotwordCorrectorTests
{
    private static readonly Dictionary<char, string> Map = new()
    {
        ['朗'] = "lang", ['诗'] = "shi", ['德'] = "de",
        ['狼'] = "lang", ['视'] = "shi", ['得'] = "de",
        ['森'] = "sen", ['派'] = "pai",
        ['盛'] = "sheng",
    };

    private static HotwordCorrector Corrector(params string[] hotwords) =>
        new(hotwords, new FakePinyin(Map));

    [Fact]
    public void Corrects_Homophone()
    {
        var corrector = Corrector("朗诗德");
        Assert.Equal("我买了一台朗诗德净水器", corrector.Correct("我买了一台狼视得净水器"));
    }

    [Fact]
    public void Corrects_NearMissWithinThreshold()
    {
        // 「森派」vs「盛派」：senpai vs shengpai，编辑距离在阈值内应纠正
        var corrector = Corrector("盛派");
        Assert.Equal("盛派公司发布了新品", corrector.Correct("森派公司发布了新品"));
    }

    [Fact]
    public void DoesNotTouch_UnrelatedText()
    {
        var corrector = Corrector("朗诗德");
        string text = "今天天气很好，我们去公园散步。";
        Assert.Equal(text, corrector.Correct(text));
    }

    [Fact]
    public void DoesNotTouch_EnglishAndDigits()
    {
        var corrector = Corrector("朗诗德");
        string text = "The price is 123 dollars.";
        Assert.Equal(text, corrector.Correct(text));
    }

    [Fact]
    public void EmptyHotwords_NoOp()
    {
        var corrector = Corrector();
        Assert.Equal("随便什么文本", corrector.Correct("随便什么文本"));
    }

    [Fact]
    public void ExactMatch_Unchanged()
    {
        var corrector = Corrector("朗诗德");
        Assert.Equal("朗诗德净水器很好", corrector.Correct("朗诗德净水器很好"));
    }

    // ----- Levenshtein -----

    [Fact]
    public void Levenshtein_Basics()
    {
        Assert.Equal(0, HotwordCorrector.Levenshtein("abc", "abc"));
        Assert.Equal(3, HotwordCorrector.Levenshtein("", "abc"));
        Assert.Equal(2, HotwordCorrector.Levenshtein("senpai", "shengpai")); // sh 插入 + g 插入
        Assert.Equal(1, HotwordCorrector.Levenshtein("langshide", "langshjde")); // 插入 j
    }

    // ----- TinyPinyin 真实库输出对齐 macOS 用例 -----

    [Fact]
    public void TinyPinyin_MatchesMacosExpectation()
    {
        var provider = new TinyPinyinProvider();
        Assert.Equal("langshide", provider.Pinyin("朗诗德"));
        Assert.Equal("langshide", provider.Pinyin("狼视得"));
    }
}
