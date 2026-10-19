using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class DevGlossaryTests
{
    [Fact]
    public void Contains_CommonTerms()
    {
        foreach (var term in new[] { "Kubernetes", "CI/CD", "GraphQL", "WebSocket" })
            Assert.Contains(term, DevGlossary.Terms);
    }

    [Fact]
    public void Merged_DedupCaseInsensitive()
    {
        var merged = DevGlossary.MergedWithUser(new[] { "kubernetes", "Vue" });
        Assert.Single(merged.Where(t => t.Equals("kubernetes", StringComparison.OrdinalIgnoreCase)));
        Assert.Equal("kubernetes", merged[0]);
    }

    [Fact]
    public void Merged_KeepsAllUserFirst()
    {
        var user = new[] { "自研平台", "TensorFlow" };
        var merged = DevGlossary.MergedWithUser(user);
        Assert.Equal(user, merged.Take(2));
        Assert.True(merged.Count > user.Length);
    }
}

public class PolishPromptV7Tests
{
    [Theory]
    [InlineData(PromptTemplates.Clean)]
    [InlineData(PromptTemplates.Formal)]
    public void Templates_ContainTermProtection(string template)
    {
        Assert.Contains("原样保留", template);
        Assert.Contains("禁止翻译", template);
        Assert.Contains("中英混合", template);
    }

    [Fact]
    public void Templates_HaveCodeSwitchExamples()
    {
        Assert.Contains("refactor", PromptTemplates.Clean);
        Assert.Contains("replicas", PromptTemplates.Clean);
    }
}
