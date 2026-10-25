using System.Linq;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class RepetitionGuardTests
{
    [Fact]
    public void Collapse_RunawayLoopToOneCopy()
    {
        // 2026-10-23 实测：Fun-ASR-Nano 在「再按 ⌥⌘V」处卡住，输出上百个「CTRL、」
        string looped = "再按" + string.Concat(Enumerable.Repeat("CTRL、", 120)) + "\n这时如果失败";
        Assert.Equal("再按CTRL、\n这时如果失败", RepetitionGuard.Collapse(looped));
    }

    [Fact]
    public void Collapse_KeepsShortRepeats()
    {
        Assert.Equal("好的好的好的好的好的", RepetitionGuard.Collapse("好的好的好的好的好的"));
        Assert.Equal("对对对，就是这样", RepetitionGuard.Collapse("对对对，就是这样"));
    }

    [Fact]
    public void Collapse_SingleCharacterKeepsThree()
    {
        Assert.Equal("哈哈哈", RepetitionGuard.Collapse("哈哈哈哈哈哈哈哈"));
        Assert.Equal("好好好吧", RepetitionGuard.Collapse("好好好好好好好吧"));
    }

    [Fact]
    public void Collapse_LongerUnits()
    {
        Assert.Equal(
            "abcd",
            RepetitionGuard.Collapse(string.Concat(Enumerable.Repeat("abc", 7)) + "d"));
        Assert.Equal(
            "谢谢观看。",
            RepetitionGuard.Collapse(string.Concat(Enumerable.Repeat("谢谢观看。", 6))));
    }

    [Fact]
    public void Collapse_LeavesDigitsAlone()
    {
        Assert.Equal("验证码是000000", RepetitionGuard.Collapse("验证码是000000"));
        Assert.Equal("1212121212121212", RepetitionGuard.Collapse("1212121212121212"));
    }

    [Fact]
    public void Collapse_LeavesOrdinaryTextAlone()
    {
        string text = "帮我看看这个报错，重点关注表格和图表。";
        Assert.Equal(text, RepetitionGuard.Collapse(text));
        Assert.Equal("", RepetitionGuard.Collapse(""));
    }
}
