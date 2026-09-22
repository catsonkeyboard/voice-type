using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VoiceType.Services;

/// <summary>
/// LLM 润色客户端（OpenAI 兼容协议）。
/// 任何失败（超时/网络/HTTP 错误/空响应/超长跑偏）返回 null，调用方回退原文——永不阻断输出。
/// </summary>
public sealed class PolishService
{
    public sealed record ProbeResult(bool Reachable, List<string> Models, string? ErrorMessage);

    private readonly HttpClient _client;
    private readonly Func<PolishConfig> _configProvider;

    public PolishService(HttpClient? client = null, Func<PolishConfig>? configProvider = null)
    {
        _client = client ?? new HttpClient();
        _configProvider = configProvider ?? (() => SettingsStore.Default.PolishConfig);
    }

    /// <summary>润色文本；null 表示"用原文"（短文本跳过或任何失败）</summary>
    public async Task<string?> Polish(string text, CancellationToken ct = default)
    {
        string input = text.Trim();
        if (input.Length < 5)
            return null;
        PolishConfig config = _configProvider();
        HttpRequestMessage? request = MakeChatRequest(
            PromptTemplates.System(config.Style), input, config, timeoutSeconds: 15);
        if (request is null)
            return null;
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(15 + 2));
            using HttpResponseMessage response = await _client.SendAsync(request, cts.Token);
            if (!response.IsSuccessStatusCode)
                return null;
            string? content = await ParseContent(response, cts.Token);
            if (content is null)
                return null;
            string cleaned = StripThinking(content).Trim();
            if (cleaned.Length == 0 || cleaned.Length > input.Length * 3)
                return null;
            return cleaned;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>通用补全（会议纪要等场景复用润色的 LLM 通道与配置；60 秒超时，无长度防跑偏校验）</summary>
    public async Task<string?> Complete(string system, string user, CancellationToken ct = default)
    {
        PolishConfig config = _configProvider();
        HttpRequestMessage? request = MakeChatRequest(system, user, config, timeoutSeconds: 60);
        if (request is null)
            return null;
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(60 + 2));
            using HttpResponseMessage response = await _client.SendAsync(request, cts.Token);
            if (!response.IsSuccessStatusCode)
                return null;
            string? content = await ParseContent(response, cts.Token);
            if (content is null)
                return null;
            string cleaned = StripThinking(content).Trim();
            return cleaned.Length == 0 ? null : cleaned;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>启动预热：请求一次让服务端把模型载入（fire-and-forget）。</summary>
    public void WarmUp() => _ = Task.Run(() => Polish("预热请求，请原样输出这句话。"));

    /// <summary>连通性检测 + 列出已装模型（Ollama /api/tags；非 Ollama 端点连通但列表为空）</summary>
    public async Task<ProbeResult> Probe(CancellationToken ct = default)
    {
        PolishConfig config = _configProvider();
        if (!Uri.TryCreate(config.BaseUrl, UriKind.Absolute, out Uri? baseUri) ||
            string.IsNullOrEmpty(baseUri.Host))
        {
            return new ProbeResult(false, [], "服务地址无效");
        }
        string port = baseUri.IsDefaultPort ? "" : $":{baseUri.Port}";
        string tagsUrl = $"{baseUri.Scheme}://{baseUri.Host}{port}/api/tags";
        try
        {
            using var resp = await _client.GetAsync(tagsUrl, ct);
            if (resp.IsSuccessStatusCode)
            {
                var tags = await resp.Content.ReadFromJsonAsync<TagsResponse>(cancellationToken: ct);
                return new ProbeResult(true, tags?.Models.Select(m => m.Name).ToList() ?? [], null);
            }
            return new ProbeResult(true, [], null);
        }
        catch (Exception e)
        {
            return new ProbeResult(false, [], e.Message);
        }
    }

    // ----- 私有 -----

    private sealed class ChatMessage
    {
        [JsonPropertyName("role")] public string Role { get; set; } = "";
        [JsonPropertyName("content")] public string Content { get; set; } = "";
    }

    private sealed class ChatRequest
    {
        [JsonPropertyName("model")] public string Model { get; set; } = "";
        [JsonPropertyName("messages")] public List<ChatMessage> Messages { get; set; } = [];
        [JsonPropertyName("temperature")] public double Temperature { get; set; }
        [JsonPropertyName("stream")] public bool Stream { get; set; }
        /// <summary>Ollama 专属：模型保活时长（null 不出现在 JSON）</summary>
        [JsonPropertyName("keep_alive")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? KeepAlive { get; set; }
        /// <summary>
        /// Ollama 专属：关闭 qwen 等混合推理模型的 thinking（/v1 端点原生 think 参数无效，
        /// 必须用 reasoning_effort=none，否则先生成大段推理导致超时）
        /// </summary>
        [JsonPropertyName("reasoning_effort")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? ReasoningEffort { get; set; }
    }

    private sealed class ChatResponse
    {
        public sealed class Choice
        {
            public sealed class Message
            {
                [JsonPropertyName("content")] public string? Content { get; set; }
            }
            [JsonPropertyName("message")] public Message Msg { get; set; } = new();
        }
        [JsonPropertyName("choices")] public List<Choice> Choices { get; set; } = [];
    }

    private sealed class TagsResponse
    {
        public sealed class ModelEntry
        {
            [JsonPropertyName("name")] public string Name { get; set; } = "";
        }
        [JsonPropertyName("models")] public List<ModelEntry> Models { get; set; } = [];
    }

    private static readonly JsonSerializerOptions BodyOpts = new(JsonSerializerDefaults.Web);

    private HttpRequestMessage? MakeChatRequest(
        string system, string user, PolishConfig config, int timeoutSeconds)
    {
        string baseUrl = config.BaseUrl.EndsWith('/')
            ? config.BaseUrl[..^1]
            : config.BaseUrl;
        if (!Uri.TryCreate(baseUrl + "/chat/completions", UriKind.Absolute, out Uri? url))
            return null;
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        var chatBody = new ChatRequest
        {
            Model = config.Model,
            Messages =
            [
                new ChatMessage { Role = "system", Content = system },
                new ChatMessage { Role = "user", Content = user },
            ],
            Temperature = 0.2,
            Stream = false,
            // keep_alive / reasoning_effort 是 Ollama 专属参数，
            // OpenAI 等云端 API 会以 400 拒绝未知参数——仅本机端点携带
            KeepAlive = IsLocalHost(url.Host) ? "10m" : null,
            ReasoningEffort = IsLocalHost(url.Host) ? "none" : null,
        };
        request.Content = new StringContent(
            JsonSerializer.Serialize(chatBody, BodyOpts), System.Text.Encoding.UTF8, "application/json");
        if (!string.IsNullOrEmpty(config.ApiKey))
            request.Headers.Authorization = new("Bearer", config.ApiKey);
        return request;
    }

    private static bool IsLocalHost(string host) =>
        host is "localhost" or "127.0.0.1";

    private static async Task<string?> ParseContent(HttpResponseMessage response, CancellationToken ct)
    {
        ChatResponse? body;
        try
        {
            byte[] bytes = await response.Content.ReadAsByteArrayAsync(ct);
            body = JsonSerializer.Deserialize<ChatResponse>(bytes, BodyOpts);
        }
        catch
        {
            return null;
        }
        return body?.Choices.FirstOrDefault()?.Msg.Content;
    }

    private static readonly Regex ThinkRegex =
        new(@"<think>.*?</think>", RegexOptions.Singleline | RegexOptions.Compiled);

    /// <summary>剥离 qwen 系列可能输出的 think 推理段（含未闭合兜底）。</summary>
    public static string StripThinking(string text) =>
        ThinkRegex.Replace(text, "").Replace("<think>", "");
}
