import Foundation

/// LLM 润色客户端（OpenAI 兼容协议）。
/// 任何失败（超时/网络/HTTP 错误/空响应/超长跑偏）返回 nil，调用方回退原文——永不阻断输出。
final class PolishService: @unchecked Sendable {
    struct ProbeResult {
        var reachable: Bool
        var models: [String]
        var errorMessage: String?
    }

    private let session: URLSession
    private let configProvider: @Sendable () -> PolishConfig

    init(
        session: URLSession? = nil,
        configProvider: @escaping @Sendable () -> PolishConfig = { SettingsStore.polishConfig }
    ) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.configProvider = configProvider
    }

    /// 润色文本；nil 表示"用原文"（短文本跳过或任何失败）
    func polish(_ text: String) async -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count >= 5 else { return nil }
        let config = configProvider()
        guard let request = makeChatRequest(input: input, config: config) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            guard let content = Self.parseContent(data) else { return nil }
            let cleaned = Self.stripThinking(content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= input.count * 3 else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }

    /// App 启动预热：加载模型进显存（fire-and-forget）
    func warmUp() {
        Task { _ = await polish("预热请求，请原样输出这句话。") }
    }

    /// 连通性检测 + 列出已装模型（Ollama /api/tags；非 Ollama 端点连通但列表为空）
    func probe() async -> ProbeResult {
        let config = configProvider()
        guard let base = URL(string: config.baseURL), let scheme = base.scheme,
            let host = base.host
        else {
            return ProbeResult(reachable: false, models: [], errorMessage: "服务地址无效")
        }
        let port = base.port.map { ":\($0)" } ?? ""
        guard let tagsURL = URL(string: "\(scheme)://\(host)\(port)/api/tags") else {
            return ProbeResult(reachable: false, models: [], errorMessage: "服务地址无效")
        }
        do {
            let (data, response) = try await session.data(from: tagsURL)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
                let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
            {
                return ProbeResult(
                    reachable: true, models: tags.models.map(\.name), errorMessage: nil)
            }
            return ProbeResult(reachable: true, models: [], errorMessage: nil)
        } catch {
            return ProbeResult(
                reachable: false, models: [], errorMessage: error.localizedDescription)
        }
    }

    // MARK: - 私有

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
        /// Ollama 专属：模型保活时长（合成 Codable 对 Optional 用 encodeIfPresent，nil 不出现在 JSON）
        let keepAlive: String?
        /// Ollama 专属：关闭 qwen 等混合推理模型的 thinking（/v1 端点原生 think 参数无效，
        /// 必须用 reasoning_effort=none，否则先生成大段推理导致超时）
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case keepAlive = "keep_alive"
            case reasoningEffort = "reasoning_effort"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }
        let models: [Model]
    }

    private func makeChatRequest(input: String, config: PolishConfig) -> URLRequest? {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        // keep_alive / reasoning_effort 是 Ollama 专属参数，
        // OpenAI 等云端 API 会以 400 拒绝未知参数——仅本机端点携带
        let isLocalEndpoint = ["localhost", "127.0.0.1"].contains(url.host ?? "")
        let body = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: PromptTemplates.system(for: config.style)),
                .init(role: "user", content: input),
            ],
            temperature: 0.2,
            stream: false,
            keepAlive: isLocalEndpoint ? "10m" : nil,
            reasoningEffort: isLocalEndpoint ? "none" : nil)
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private static func parseContent(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ChatResponse.self, from: data))?
            .choices.first?.message.content
    }

    /// 剥离 qwen 系列可能输出的 <think>…</think> 推理段。
    /// (?s) 打开 dotall——思考内容是多行的，默认 `.` 不匹配换行会导致剥离失败。
    private static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: "",
            options: [.regularExpression],
            range: nil)
            .replacingOccurrences(of: "<think>", with: "")  // 未闭合兜底
    }
}
