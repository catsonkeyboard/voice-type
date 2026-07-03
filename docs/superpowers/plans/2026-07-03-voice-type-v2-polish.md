# VoiceType v2 智能润色 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 v1 听写管线的 ASR 之后插入本地 LLM 润色层（Ollama MLX + qwen3.5:4b-nvfp4）：过滤口头禅、应用自我纠正、口语转书面语、自动列表化；失败永不阻断输出。

**Architecture:** 新增唯一组件 `PolishService`（OpenAI 兼容 chat 客户端，非流式，15s 超时，任何失败返回 nil 由调用方回退原文）。`DictationController` 在热词纠正后调用它；`TranscriptRecord` 新增 `rawText` 保留润色前原文；设置新增「润色」Tab。

**Tech Stack:** URLSession + OpenAI 兼容协议（`/v1/chat/completions`）/ Ollama 0.30 MLX 后端 / SwiftData 轻量迁移 / XCTest（URLProtocol mock + 可跳过的集成金标）

**已核实的事实（执行时不要再猜）：**
- 本机 Ollama 0.30.10 常驻 `localhost:11434`，作为 macOS App 运行；`nvfp4` 后缀模型加载后 runner 进程带 `--mlx-engine`（MLX 后端实证）
- 默认模型 **`qwen3.5:4b-nvfp4`**（4.0GB）。**不要在任何脚本/测试里自动 pull**——用户自行下载；模型缺失时集成测试 XCTSkip、设置页展示 pull 命令
- Ollama OpenAI 兼容端点：`POST /v1/chat/completions`；原生模型列表：`GET /api/tags` 返回 `{"models":[{"name":"..."}]}`
- qwen3.5 系列带 thinking 能力，输出可能包含 `<think>…</think>`——解析时必须剥离
- URLProtocol mock 的坑：URLSession 会把 `httpBody` 转成 `httpBodyStream`，断言请求体必须从 stream 读（计划里有现成 helper）
- v1 代码位置：`VoiceType/Services/DictationController.swift`（听写管线）、`VoiceType/Services/HistoryStore.swift`（含 `TranscriptRecord`）、`VoiceType/Services/SettingsStore.swift`、`VoiceType/App/AppState.swift`、`VoiceType/App/AppDependencies.swift`、`VoiceType/App/VoiceTypeApp.swift`、`VoiceType/UI/PanelView.swift`、`VoiceType/UI/SettingsView.swift`
- 通用命令：`xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test`；新增源文件后必须先跑 `xcodegen`

**文件结构：**

```
VoiceType/Services/PolishPrompt.swift     # PolishStyle / PolishConfig / PromptTemplates
VoiceType/Services/PolishService.swift    # OpenAI 兼容客户端 + probe
VoiceTypeTests/PolishServiceTests.swift   # mock 单测
VoiceTypeTests/PolishIntegrationTests.swift  # 金标集成（无模型时跳过）
（修改）SettingsStore / HistoryStore / DictationController / AppState /
        AppDependencies / VoiceTypeApp / PanelView / SettingsView / README.md
```

---

### Task 1: 润色配置与提示词（PolishPrompt.swift + SettingsStore 扩展）

**Files:**
- Create: `VoiceType/Services/PolishPrompt.swift`
- Modify: `VoiceType/Services/SettingsStore.swift`
- Test: `VoiceTypeTests/PolishSettingsTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/PolishSettingsTests.swift`**

```swift
import XCTest

@testable import VoiceType

final class PolishSettingsTests: XCTestCase {
    private let keys = ["polishEnabled", "polishBaseURL", "polishAPIKey", "polishModel", "polishStyle"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertTrue(SettingsStore.polishEnabled)
        XCTAssertEqual(SettingsStore.polishBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(SettingsStore.polishAPIKey, "")
        XCTAssertEqual(SettingsStore.polishModel, "qwen3.5:4b-nvfp4")
        XCTAssertEqual(SettingsStore.polishStyle, .clean)
    }

    func testRoundTrip() {
        SettingsStore.polishEnabled = false
        SettingsStore.polishStyle = .formal
        SettingsStore.polishModel = "qwen3.5:9b-nvfp4"
        XCTAssertFalse(SettingsStore.polishEnabled)
        XCTAssertEqual(SettingsStore.polishStyle, .formal)
        XCTAssertEqual(SettingsStore.polishConfig.model, "qwen3.5:9b-nvfp4")
        XCTAssertFalse(SettingsStore.polishConfig.enabled)
    }

    func testPromptTemplatesCoverGoldenScenarios() {
        for template in [PromptTemplates.system(for: .clean), PromptTemplates.system(for: .formal)] {
            XCTAssertTrue(template.contains("口头禅") || template.contains("填充词"))
            XCTAssertTrue(template.contains("自我纠正") || template.contains("纠正"))
            XCTAssertTrue(template.contains("列表"))
            XCTAssertTrue(template.contains("只输出"))
        }
    }
}
```

- [ ] **Step 2: 运行确认编译失败（PolishStyle/PromptTemplates 未定义）**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST" | head -5`
Expected: FAIL（cannot find 'PromptTemplates' / 'polishEnabled'）

- [ ] **Step 3: 实现 `VoiceType/Services/PolishPrompt.swift`**

```swift
import Foundation

enum PolishStyle: String, Codable, CaseIterable, Hashable {
    case clean    // 智能清理：保留原话风格
    case formal   // 完全书面化：允许重组句式

    var label: String {
        switch self {
        case .clean: return "智能清理"
        case .formal: return "完全书面化"
        }
    }
}

struct PolishConfig: Equatable {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var style: PolishStyle
}

enum PromptTemplates {
    static func system(for style: PolishStyle) -> String {
        switch style {
        case .clean: return clean
        case .formal: return formal
        }
    }

    /// 共同规则：口头禅过滤、自我纠正、列表化、防幻觉、纯文本输出
    private static let commonRules = """
1. 删除口头禅和填充词（呃、嗯、啊、那个、就是说、然后那个、这个这个 等）以及无意义的重复。
2. 识别并应用说话人的自我纠正：出现「不对」「不是」「说错了」「应该是」等纠正标记时，只保留纠正后的内容，删除被纠正的内容和纠正标记本身。
3. 当内容在列举事项或步骤（如「第一…第二…」「首先…然后…最后…」）时，输出为 Markdown 列表：有顺序用 1. 2. 3.，无顺序用 - 。其余情况输出普通段落。
4. 严禁添加原文没有的信息，严禁遗漏原文的实质内容。
5. 只输出处理后的文本本身，不要任何解释、前缀、引号或代码块。

示例：
输入：明天下午呃不对是明天上午九点开会
输出：明天上午九点开会。

输入：嗯我觉得这个方案就是说还有一些问题那个性能方面可能得再优化一下
输出：我觉得这个方案还有一些问题，性能方面可能得再优化一下。

输入：买菜清单第一个是西红柿第二个是鸡蛋然后还有那个牛奶
输出：买菜清单：
1. 西红柿
2. 鸡蛋
3. 牛奶

输入：这个 bug 呃我看了一下应该是 cache 没有 invalidate 导致的
输出：这个 bug 我看了一下，应该是 cache 没有 invalidate 导致的。
"""

    static let clean = """
你是一个语音转写文本的清理引擎。用户消息是一段以中文为主的语音识别原文。按以下规则处理，把口语碎片整理为通顺连贯的表达：调整语序、补全标点，但保留说话人的用词和语气，不要替换成你自己的措辞。
\(commonRules)
"""

    static let formal = """
你是一个语音转写文本的书面化引擎。用户消息是一段以中文为主的语音识别原文。按以下规则处理，并将内容改写为正式、精炼的书面语：可以重组句式、替换口语化用词，但不得改变含义。
\(commonRules)
"""
}
```

- [ ] **Step 4: 在 `VoiceType/Services/SettingsStore.swift` 末尾（enum 内部）追加**

```swift
    // MARK: - 润色（v2）

    static var polishEnabled: Bool {
        get {
            defaults.object(forKey: "polishEnabled") == nil
                ? true : defaults.bool(forKey: "polishEnabled")
        }
        set { defaults.set(newValue, forKey: "polishEnabled") }
    }

    static var polishBaseURL: String {
        get { defaults.string(forKey: "polishBaseURL") ?? "http://localhost:11434/v1" }
        set { defaults.set(newValue, forKey: "polishBaseURL") }
    }

    static var polishAPIKey: String {
        get { defaults.string(forKey: "polishAPIKey") ?? "" }
        set { defaults.set(newValue, forKey: "polishAPIKey") }
    }

    static var polishModel: String {
        get { defaults.string(forKey: "polishModel") ?? "qwen3.5:4b-nvfp4" }
        set { defaults.set(newValue, forKey: "polishModel") }
    }

    static var polishStyle: PolishStyle {
        get {
            defaults.string(forKey: "polishStyle").flatMap(PolishStyle.init(rawValue:)) ?? .clean
        }
        set { defaults.set(newValue.rawValue, forKey: "polishStyle") }
    }

    static var polishConfig: PolishConfig {
        PolishConfig(
            enabled: polishEnabled, baseURL: polishBaseURL, apiKey: polishAPIKey,
            model: polishModel, style: polishStyle)
    }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|PolishSettingsTests.*(passed|failed)|TEST " | tail -5`
Expected: 3 个用例 passed，整体 `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add VoiceType/Services/PolishPrompt.swift VoiceType/Services/SettingsStore.swift VoiceTypeTests/PolishSettingsTests.swift
git commit -m "feat(v2): 润色配置存储与提示词模板 (TDD)"
```

---

### Task 2: PolishService（TDD，URLProtocol mock）

**Files:**
- Create: `VoiceType/Services/PolishService.swift`
- Test: `VoiceTypeTests/PolishServiceTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/PolishServiceTests.swift`**

```swift
import XCTest

@testable import VoiceType

/// URLProtocol mock：拦截 PolishService 的所有请求
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession 会把 httpBody 转为 stream，断言请求体必须从这里读
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class PolishServiceTests: XCTestCase {
    private var service: PolishService!

    private static let config = PolishConfig(
        enabled: true, baseURL: "http://localhost:11434/v1", apiKey: "",
        model: "test-model", style: .clean)

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        service = PolishService(
            session: URLSession(configuration: cfg),
            configProvider: { Self.config })
    }

    private func stubSuccess(content: String) {
        MockURLProtocol.handler = { request in
            let json = [
                "choices": [["message": ["role": "assistant", "content": content]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
    }

    func testShortInputSkipsWithoutNetwork() async {
        stubSuccess(content: "不应到达")
        let result = await service.polish("好的")
        XCTAssertNil(result)
        XCTAssertTrue(MockURLProtocol.recordedRequests.isEmpty)
    }

    func testRequestFormat() async throws {
        stubSuccess(content: "润色结果。")
        _ = await service.polish("嗯这是一段测试文本")

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/chat/completions"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 15)

        let body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(request.bodyData)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "30m")
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertTrue(messages[0]["content"]!.contains("口头禅"))
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "嗯这是一段测试文本")
    }

    func testAPIKeyAddsAuthorizationHeader() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let cloudService = PolishService(
            session: URLSession(configuration: cfg),
            configProvider: {
                PolishConfig(
                    enabled: true, baseURL: "https://api.example.com/v1", apiKey: "sk-test",
                    model: "m", style: .clean)
            })
        stubSuccess(content: "结果")
        _ = await cloudService.polish("嗯这是一段测试文本")
        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSuccessReturnsTrimmedContent() async {
        stubSuccess(content: "\n  明天上午九点开会。  \n")
        let result = await service.polish("明天下午呃不对是明天上午九点开会")
        XCTAssertEqual(result, "明天上午九点开会。")
    }

    func testStripsThinkTags() async {
        stubSuccess(content: "<think>用户想清理文本…\n多行思考</think>\n明天上午九点开会。")
        let result = await service.polish("明天下午呃不对是明天上午九点开会")
        XCTAssertEqual(result, "明天上午九点开会。")
    }

    func testHTTPErrorReturnsNil() async {
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testNetworkErrorReturnsNil() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testEmptyContentReturnsNil() async {
        stubSuccess(content: "   ")
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testOverlongContentReturnsNil() async {
        stubSuccess(content: String(repeating: "废", count: 200))
        let result = await service.polish("嗯这是一段测试文本")  // 9 字，3 倍上限 27
        XCTAssertNil(result)
    }

    func testProbeParsesOllamaTags() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            let json = ["models": [["name": "qwen3.5:4b-nvfp4"], ["name": "other:1b"]]]
            let data = try JSONSerialization.data(withJSONObject: json)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let result = await service.probe()
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.models, ["qwen3.5:4b-nvfp4", "other:1b"])
    }

    func testProbeConnectionRefused() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let result = await service.probe()
        XCTAssertFalse(result.reachable)
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNotNil(result.errorMessage)
    }
}
```

- [ ] **Step 2: 运行确认编译失败（PolishService 未定义）**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST" | head -5`
Expected: FAIL

- [ ] **Step 3: 实现 `VoiceType/Services/PolishService.swift`**

```swift
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
        let keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case keepAlive = "keep_alive"
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
        let body = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: PromptTemplates.system(for: config.style)),
                .init(role: "user", content: input),
            ],
            temperature: 0.2,
            stream: false,
            keepAlive: "30m")
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
```

- [ ] **Step 4: 运行测试确认全部通过**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|PolishServiceTests.*(passed|failed)|TEST " | tail -8`
Expected: 11 个用例 passed，`** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add VoiceType/Services/PolishService.swift VoiceTypeTests/PolishServiceTests.swift
git commit -m "feat(v2): PolishService OpenAI 兼容润色客户端 (TDD)"
```

---

### Task 3: 历史保留原始转写（rawText）

**Files:**
- Modify: `VoiceType/Services/HistoryStore.swift`
- Modify: `VoiceType/UI/PanelView.swift`（HistoryRow 右键菜单）
- Test: `VoiceTypeTests/HistoryStoreTests.swift`（追加用例）

- [ ] **Step 1: 在 `HistoryStoreTests` 追加失败用例**

```swift
    func testRawTextStored() throws {
        let store = try makeStore()
        store.add(text: "润色后", durationSeconds: 1, source: "dictation", rawText: "嗯润色前")
        store.add(text: "无润色", durationSeconds: 1, source: "dictation")
        let records = store.recent(limit: 10)
        XCTAssertEqual(records[0].rawText, nil)
        XCTAssertEqual(records[1].rawText, "嗯润色前")
    }
```

- [ ] **Step 2: 运行确认编译失败（rawText 未定义）**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -3`
Expected: FAIL（no member 'rawText' / extra argument）

- [ ] **Step 3: 修改 `VoiceType/Services/HistoryStore.swift`**

`TranscriptRecord` 增加字段与 init 参数（可选字段，SwiftData 轻量迁移自动兼容旧库）：

```swift
@Model
final class TranscriptRecord {
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var source: String  // "dictation" | "file"
    var rawText: String?  // 润色前原始转写；未润色为 nil

    init(
        text: String, createdAt: Date = .now, durationSeconds: Double = 0,
        source: String = "dictation", rawText: String? = nil
    ) {
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.source = source
        self.rawText = rawText
    }
}
```

`HistoryStore.add` 签名增加默认参数（旧调用不受影响）：

```swift
    func add(text: String, durationSeconds: Double, source: String, rawText: String? = nil) {
        context.insert(
            TranscriptRecord(
                text: text, durationSeconds: durationSeconds, source: source, rawText: rawText))
        try? context.save()
        trim()
        try? context.save()
    }
```

- [ ] **Step 4: `PanelView.swift` 的 `HistoryRow.contextMenu` 增加复制原文**

```swift
        .contextMenu {
            if let rawText = record.rawText {
                Button("复制原始转写") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawText, forType: .string)
                }
            }
            Button("删除", role: .destructive, action: onDelete)
        }
```

- [ ] **Step 5: 运行测试确认通过 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST " | tail -3`
Expected: `** TEST SUCCEEDED **`

```bash
git add VoiceType/Services/HistoryStore.swift VoiceType/UI/PanelView.swift VoiceTypeTests/HistoryStoreTests.swift
git commit -m "feat(v2): 历史记录保留润色前原始转写"
```

---

### Task 4: 听写管线接入（.polishing 状态 + 降级提示）

**Files:**
- Modify: `VoiceType/App/AppState.swift`（Phase 加 case）
- Modify: `VoiceType/Services/DictationController.swift`
- Modify: `VoiceType/App/AppDependencies.swift`
- Modify: `VoiceType/App/VoiceTypeApp.swift`（图标）
- Modify: `VoiceType/UI/PanelView.swift`（状态文案/按钮禁用）

- [ ] **Step 1: `AppState.Phase` 增加 `.polishing`**

```swift
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
        case error(String)
    }
```

- [ ] **Step 2: `DictationController` 注入 PolishService 并接入管线**

init 与属性改为：

```swift
    let state: AppState
    let asr: AsrService
    let polish: PolishService
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private var capTimer: Timer?
    private var promptedAccessibility = false

    init(state: AppState, asr: AsrService, history: HistoryStore, polish: PolishService) {
        self.state = state
        self.asr = asr
        self.history = history
        self.polish = polish
    }
```

`toggle()` 的 switch 补 case（识别/润色中忽略触发）：

```swift
        case .transcribing, .polishing:
            break
```

`finishRecording()` 中，从热词纠正到注入的段落整体替换为：

```swift
            var text = try await asr.transcribe(samples: samples)
            text = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
            guard !text.isEmpty else {
                state.phase = .idle
                HUDController.shared.hide()
                return
            }
            var rawText: String? = nil
            var polishDegraded = false
            if SettingsStore.polishEnabled, text.count >= 5 {
                state.phase = .polishing
                if let polished = await polish.polish(text) {
                    if polished != text { rawText = text }
                    text = polished
                } else {
                    polishDegraded = true
                }
            }
            history.add(
                text: text, durationSeconds: duration, source: "dictation", rawText: rawText)
            let result = TextInjector.inject(text)
            state.phase = .idle
            switch result {
            case .injected:
                if polishDegraded {
                    HUDController.shared.flash("润色不可用，已输出原文", state: state)
                } else {
                    HUDController.shared.hide()
                }
            case .copiedToClipboard:
                HUDController.shared.flash("已复制到剪贴板，请按 ⌘V 粘贴", state: state)
                if !TextInjector.isTrusted, !promptedAccessibility {
                    promptedAccessibility = true
                    TextInjector.promptForAccessibility()
                }
            }
```

- [ ] **Step 3: `AppDependencies` 创建并预热 PolishService**

```swift
    let polish: PolishService
```

init 中（`asr = AsrService()` 之后）：

```swift
        polish = PolishService()
        dictation = DictationController(state: state, asr: asr, history: history, polish: polish)
```

（替换原 `dictation = DictationController(state:asr:history:)` 行），并在 `asr.warmUp()` 后追加：

```swift
        if SettingsStore.polishEnabled {
            polish.warmUp()
        }
```

- [ ] **Step 4: UI 状态适配**

`VoiceTypeApp.menuBarIcon` 加：

```swift
        case .polishing: return "sparkles"
```

`PanelView.statusColor` 加：

```swift
        case .polishing: return .purple
```

`PanelView.statusText` 加：

```swift
        case .polishing: return "润色中…"
```

`PanelView.recordButton` 的 disabled 条件改为：

```swift
        .disabled(
            deps.state.phase == .transcribing || deps.state.phase == .polishing
                || !deps.state.modelsReady)
```

`RecordingHUD.swift` 的 `RecordingHUDView` switch 中 `.transcribing` case 之后加：

```swift
                case .polishing:
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("润色中…")
                        .foregroundStyle(.secondary)
```

- [ ] **Step 5: 全量测试 + Commit**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST " | tail -3`
Expected: `** TEST SUCCEEDED **`（Swift 的 exhaustive switch 会强制所有遗漏的 case 在编译期暴露）

```bash
git add VoiceType
git commit -m "feat(v2): 听写管线接入润色（polishing 状态/降级提示/预热）"
```

---

### Task 5: 设置「润色」Tab

**Files:**
- Modify: `VoiceType/UI/SettingsView.swift`

- [ ] **Step 1: `SettingsView` 的 TabView 增加第三个 Tab**

```swift
            PolishSettingsView()
                .tabItem { Label("润色", systemImage: "sparkles") }
```

- [ ] **Step 2: 在 `SettingsView.swift` 文件末尾追加**

```swift
private struct PolishSettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var enabled = SettingsStore.polishEnabled
    @State private var style = SettingsStore.polishStyle
    @State private var baseURL = SettingsStore.polishBaseURL
    @State private var apiKey = SettingsStore.polishAPIKey
    @State private var model = SettingsStore.polishModel
    @State private var probing = false
    @State private var probeResult: PolishService.ProbeResult?

    var body: some View {
        Form {
            Section("智能润色") {
                Toggle("启用润色（关闭后输出原始转写）", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        SettingsStore.polishEnabled = newValue
                        if newValue { deps.polish.warmUp() }
                    }
                Picker("风格", selection: $style) {
                    ForEach(PolishStyle.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .onChange(of: style) { _, newValue in
                    SettingsStore.polishStyle = newValue
                }
            }

            Section("服务（OpenAI 兼容，默认本地 Ollama）") {
                TextField("服务地址", text: $baseURL)
                    .onChange(of: baseURL) { _, v in SettingsStore.polishBaseURL = v }
                SecureField("API Key（本地 Ollama 留空）", text: $apiKey)
                    .onChange(of: apiKey) { _, v in SettingsStore.polishAPIKey = v }
                TextField("模型", text: $model)
                    .onChange(of: model) { _, v in SettingsStore.polishModel = v }
                if let models = probeResult?.models, !models.isEmpty {
                    Menu("从已装模型中选择") {
                        ForEach(models, id: \.self) { name in
                            Button(name) {
                                model = name
                                SettingsStore.polishModel = name
                            }
                        }
                    }
                }
                Button(probing ? "检测中…" : "测试连接") {
                    probing = true
                    probeResult = nil
                    Task {
                        probeResult = await deps.polish.probe()
                        probing = false
                    }
                }
                .disabled(probing)
                if let result = probeResult {
                    probeStatus(result)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func probeStatus(_ result: PolishService.ProbeResult) -> some View {
        if !result.reachable {
            Label(
                "无法连接：\(result.errorMessage ?? "未知错误")（Ollama 是否在运行？）",
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
            .font(.caption)
        } else if result.models.isEmpty {
            Label("已连接（该服务不支持列出模型）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if result.models.contains(model) {
            Label("已连接，模型可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("已连接，但模型未安装", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                HStack {
                    Text("ollama pull \(model)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("复制命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ollama pull \(model)", forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
```

- [ ] **Step 3: 构建 + 全量测试 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST " | tail -3`
Expected: `** TEST SUCCEEDED **`

```bash
git add VoiceType/UI/SettingsView.swift
git commit -m "feat(v2): 设置窗口润色 Tab（开关/风格/端点/模型/测试连接）"
```

---

### Task 6: 金标集成测试 + README + 构建交付

**Files:**
- Create: `VoiceTypeTests/PolishIntegrationTests.swift`
- Modify: `README.md`

- [ ] **Step 1: 写 `VoiceTypeTests/PolishIntegrationTests.swift`**

模型未下载或 Ollama 未运行时自动 XCTSkip——**不要在测试里 pull 模型**：

```swift
import XCTest

@testable import VoiceType

/// 金标集成测试：验证真实模型的四项核心能力。
/// Ollama 未运行或模型未下载时自动跳过（提示 pull 命令）。
final class PolishIntegrationTests: XCTestCase {
    static let model = "qwen3.5:4b-nvfp4"

    private func makeService() -> PolishService {
        PolishService(configProvider: {
            PolishConfig(
                enabled: true, baseURL: "http://localhost:11434/v1", apiKey: "",
                model: Self.model, style: .clean)
        })
    }

    /// 前置检查 + 预热（首次加载模型可能较慢，先打一发让正式请求走热路径）
    private func requireModel(_ service: PolishService) async throws {
        let probe = await service.probe()
        try XCTSkipUnless(probe.reachable, "Ollama 未运行，跳过集成测试")
        try XCTSkipUnless(
            probe.models.contains(Self.model),
            "模型未下载，请运行: ollama pull \(Self.model)")
        _ = await service.polish("预热请求，请原样输出这句话。")
    }

    func testGoldenFillerRemoval() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("嗯我觉得这个方案就是说还有一些问题那个性能方面可能得再优化一下")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-口头禅: \(result)")
        XCTAssertFalse(result.contains("嗯"))
        XCTAssertFalse(result.contains("就是说"))
        XCTAssertFalse(result.contains("那个"))
        XCTAssertTrue(result.contains("性能"))
    }

    func testGoldenSelfCorrection() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("明天下午呃不对是明天上午九点开会")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-自我纠正: \(result)")
        XCTAssertTrue(result.contains("上午"))
        XCTAssertFalse(result.contains("下午"))
        XCTAssertFalse(result.contains("不对"))
    }

    func testGoldenListFormatting() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("买菜清单第一个是西红柿第二个是鸡蛋第三个是牛奶")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-列表化: \(result)")
        for item in ["西红柿", "鸡蛋", "牛奶"] {
            XCTAssertTrue(result.contains(item), "缺少列举项 \(item)")
        }
        XCTAssertTrue(
            result.contains("1.") || result.contains("- "),
            "未格式化为列表: \(result)")
    }

    func testGoldenFluency() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("这个 bug 呃我看了一下应该是 cache 没有 invalidate 导致的")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-连贯化: \(result)")
        XCTAssertFalse(result.contains("呃"))
        XCTAssertTrue(result.contains("cache"))
        XCTAssertTrue(result.contains("invalidate"))
    }
}
```

- [ ] **Step 2: 运行全量测试**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|skipped|Executed .* tests|TEST " | tail -8`
Expected: `** TEST SUCCEEDED **`。模型未下载时 4 个金标用例显示 skipped（提示 pull 命令）；模型就位后应全部 passed——**这是默认模型的质量闸门**，任何一个金标失败则按 spec 升级路径换 `4b-mxfp8` 或 `9b-nvfp4` 重测。

- [ ] **Step 3: README 增加 v2 说明**

在「功能」列表最上方加一行：

```markdown
- **智能润色（v2）**：本地 LLM（Ollama + MLX）把口语碎片转为书面语——过滤"呃/嗯/那个"等口头禅、识别自我纠正（"明天下午…不对，上午九点" → "明天上午九点"）、自动把列举内容排成列表；润色不可用时自动降级输出原始转写
```

在「构建」小节之后新增：

```markdown
## 智能润色（v2）

润色依赖本地 Ollama（≥0.19，MLX 后端）与模型（用户自行下载）：

    ollama pull qwen3.5:4b-nvfp4   # 4GB，MLX/NVFP4 量化

默认配置即用（`http://localhost:11434/v1`）。设置 → 润色 可关闭功能、切换"智能清理/完全书面化"风格、更换模型或指向任何 OpenAI 兼容服务（如 LM Studio、云端 API）。历史记录保留润色前原文（右键 → 复制原始转写）。
```

- [ ] **Step 4: 构建安装 + 最终提交**

```bash
./scripts/install.sh
git add -A
git commit -m "feat(v2): 智能润色完成（金标集成测试 + README）"
```

- [ ] **Step 5: 交付给用户的验收清单（写进交付说明，不自动执行）**

1. 下载模型：`ollama pull qwen3.5:4b-nvfp4`（4GB）
2. 跑金标：`xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test -only-testing:VoiceTypeTests/PolishIntegrationTests`，4 个用例应全过
3. ⌥Space 说"嗯明天下午呃不对是明天上午九点开会"→ 光标处出现"明天上午九点开会。"，HUD 依次显示 识别中→润色中✨
4. 说一段带"第一…第二…"的列举 → 输出为编号列表
5. 设置 → 润色：测试连接显示绿色"已连接，模型可用"；切风格、关开关行为符合预期
6. 停掉 Ollama 再听写 → 正常输出原始转写 + HUD 提示"润色不可用"

---

## 与 spec 的对照（自查结论）

- 四项核心能力 → 提示词模板（Task 1）+ 金标集成（Task 6）
- 降级永不阻断 → PolishService 全失败路径返回 nil（Task 2）+ 管线回退与 HUD 提示（Task 4）
- 热词纠正在润色前 → Task 4 管线顺序
- <5 字跳过 / 15s 超时 / 3 倍长度防跑偏 / <think> 剥离 → Task 2 实现与单测
- rawText 历史 + 右键复制 → Task 3
- `.polishing` 状态 + sparkles 图标 → Task 4
- 设置 Tab（开关/风格/端点/Key/模型/测试连接/pull 指引）→ Task 5
- 模型不自动下载 → 全计划无 pull 命令；测试 skip + 设置页指引（Task 5/6）
- 文件转写不接润色 → DictationController.transcribeFile 未改动（保持 v1 行为）
