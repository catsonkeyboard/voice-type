using System.Net;
using System.Net.Http;
using System.Text;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

/// <summary>可编程 HttpMessageHandler：按请求返回预置响应。</summary>
sealed class FakeHttpHandler : HttpMessageHandler
{
    public List<(HttpRequestMessage Request, string? Body)> Requests { get; } = [];

    private readonly Func<HttpRequestMessage, string?, HttpResponseMessage> _respond;

    public FakeHttpHandler(Func<HttpRequestMessage, string?, HttpResponseMessage> respond) =>
        _respond = respond;

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken ct)
    {
        string? body = request.Content is null
            ? null
            : request.Content.ReadAsStringAsync(ct).Result;
        Requests.Add((request, body));
        return Task.FromResult(_respond(request, body));
    }
}

public class PolishServiceTests
{
    private const string LongInput = "这是一段足够长的语音转写原文，用于触发润色流程。";

    private static PolishConfig Config(string url = "http://localhost:11434/v1") => new(
        true, url, "", "test-model", PolishStyle.Clean);

    private static HttpResponseMessage Ok(string content)
    {
        var payload = new
        {
            choices = new[] { new { message = new { content } } },
        };
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                System.Text.Json.JsonSerializer.Serialize(payload),
                Encoding.UTF8, "application/json"),
        };
    }

    private static HttpResponseMessage Bad() => new(HttpStatusCode.BadRequest)
    {
        Content = new StringContent("""{"error":"bad"}""", Encoding.UTF8, "application/json"),
    };

    private static PolishService Service(
        Func<HttpRequestMessage, string?, HttpResponseMessage> respond,
        PolishConfig? config = null)
    {
        config ??= Config();
        return new PolishService(
            new HttpClient(new FakeHttpHandler(respond)), () => config);
    }

    [Fact]
    public async Task Polish_ReturnsCleanedContent()
    {
        string? captured = null;
        var svc = Service((req, body) =>
        {
            captured = body;
            return Ok("润色后的文本。");
        });
        string? result = await svc.Polish(LongInput);
        Assert.Equal("润色后的文本。", result);
        Assert.NotNull(captured);
        Assert.Contains("test-model", captured);
    }

    [Fact]
    public async Task Polish_StripsThinkingBlock()
    {
        var svc = Service((req, body) => Ok("<think>推理过程\n多行</think>实际输出"));
        string? result = await svc.Polish(LongInput);
        Assert.Equal("实际输出", result);
    }

    [Fact]
    public async Task Polish_StripsUnclosedThink()
    {
        var svc = Service((req, body) => Ok("<think>未闭合的内容实际输出"));
        string? result = await svc.Polish(LongInput);
        Assert.Equal("未闭合的内容实际输出", result);
    }

    [Fact]
    public async Task Polish_TooLongOutputFallsBackToNull()
    {
        // 超过原文 3 倍视为跑偏
        var svc = Service((req, body) => Ok(new string('字', LongInput.Length * 4)));
        Assert.Null(await svc.Polish(LongInput));
    }

    [Fact]
    public async Task Polish_HttpErrorFallsBackToNull()
    {
        var svc = Service((req, body) => Bad());
        Assert.Null(await svc.Polish(LongInput));
    }

    [Fact]
    public async Task Polish_ShortInputSkipped()
    {
        var svc = Service((req, body) => throw new InvalidOperationException("不应发起请求"));
        Assert.Null(await svc.Polish("短的"));
    }

    [Fact]
    public async Task Polish_LocalEndpointGetsOllamaParams()
    {
        string? body = null;
        var svc = Service((req, b) =>
        {
            body = b;
            return Ok("ok");
        });
        await svc.Polish(LongInput);
        Assert.NotNull(body);
        Assert.Contains("\"keep_alive\":\"10m\"", body);
        Assert.Contains("\"reasoning_effort\":\"none\"", body);
    }

    [Fact]
    public async Task Polish_CloudEndpointOmitsOllamaParams()
    {
        string? body = null;
        var svc = Service((req, b) =>
        {
            body = b;
            return Ok("ok");
        }, Config("https://api.deepseek.com/v1"));
        await svc.Polish(LongInput);
        Assert.NotNull(body);
        Assert.DoesNotContain("keep_alive", body);
        Assert.DoesNotContain("reasoning_effort", body);
    }

    [Fact]
    public async Task Complete_ReturnsContent_WithoutLengthGuard()
    {
        string longText = new('字', 500);
        var svc = Service((req, body) => Ok(longText));
        string? result = await svc.Complete("system", "user");
        Assert.Equal(longText, result);
    }

    [Fact]
    public void StripThinking_RemovesBlock()
    {
        Assert.Equal("结果", PolishService.StripThinking("<think>a\nb</think>结果"));
        Assert.Equal("结果", PolishService.StripThinking("结<think>x</think>果"));
    }

    // ----- probe -----

    [Fact]
    public async Task Probe_ListsOllamaModels()
    {
        var svc = Service((req, _) =>
        {
            if (req.RequestUri!.AbsolutePath.EndsWith("/api/tags"))
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(
                        """{"models":[{"name":"qwen3.5:4b"},{"name":"llama3"}]}""",
                        Encoding.UTF8, "application/json"),
                };
            }
            return Bad();
        });
        PolishService.ProbeResult result = await svc.Probe();
        Assert.True(result.Reachable);
        Assert.Equal(["qwen3.5:4b", "llama3"], result.Models);
    }

    [Fact]
    public async Task Probe_Unreachable()
    {
        var svc = Service((req, _) => throw new HttpRequestException("connection refused"));
        PolishService.ProbeResult result = await svc.Probe();
        Assert.False(result.Reachable);
        Assert.NotNull(result.ErrorMessage);
    }

    [Fact]
    public async Task Probe_NonOllamaEndpoint_ReturnsEmptyModelList()
    {
        var svc = Service((req, _) => new HttpResponseMessage(HttpStatusCode.NotFound));
        PolishService.ProbeResult result = await svc.Probe();
        Assert.True(result.Reachable);
        Assert.Empty(result.Models);
    }
}
