# VoiceType v3 云端 ASR + 润色预设 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增可选云端识别引擎（阿里百炼 Fun-ASR-Realtime，WebSocket 实时流式 + HUD 实时上屏 + 失败自动回退本地），API Key 入 Keychain，润色加服务商预设并修复 Ollama 专属参数兼容性 bug。

**Architecture:** 纯逻辑（协议构造/解析/句子装配/PCM16）与 I/O 壳（URLSessionWebSocketTask 会话）分离；DictationController 按 `SettingsStore.asrEngine` 分流，录音采样全程累积保证回退；本地引擎路径零改动。

**Tech Stack:** URLSessionWebSocketTask / DashScope WebSocket 协议 / Security.framework (Keychain) / XCTest

**已核实与待实测的事实：**
- 端点 `wss://dashscope.aliyuncs.com/api-ws/v1/inference/`，握手头 `Authorization: Bearer <key>`，模型 `fun-asr-realtime`，音频 16kHz 单声道 PCM16 小端、约 100ms/帧（1600 采样 = 3200 字节）
- 消息信封（DashScope 通用协议）：客户端 `run-task`/`finish-task` 文本帧 + 二进制音频帧；服务端 `task-started`/`result-generated`/`task-finished`/`task-failed`；`result-generated` 的 `payload.output.sentence{text, sentence_end}` 中 `sentence_end=false` 为 partial（同句反复刷新）
- **本机当前无 DASHSCOPE_API_KEY**：解析器按上述文档格式编写并做防御性容错；`scripts/probe_dashscope.swift` 留给用户拿到 Key 后实测校验；集成测试无 Key 自动 XCTSkip
- 现有代码位置：`SettingsStore` / `PolishService`（`makeChatRequest` 总是带 `keep_alive`+`reasoning_effort`，这是要修的 bug）/ `AudioRecorder.process()`（tap 内转换后追加 samples 并派发 onLevel）/ `DictationController.startRecording()/finishRecording()` / `AppState.Phase` / `RecordingHUD`（NSPanel 240×56）/ `SettingsView`（TabView 通用/润色/热词）
- 通用命令：`xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test`；新增源文件后必须先 `xcodegen`

**文件结构：**

```
VoiceType/Services/KeychainStore.swift          # Keychain 薄封装
VoiceType/Services/DashScopeAsrProtocol.swift   # 协议纯逻辑 + SentenceAssembler + PCM16 + AsrEngine 枚举
VoiceType/Services/DashScopeAsrSession.swift    # WebSocket 会话壳
VoiceTypeTests/KeychainStoreTests.swift
VoiceTypeTests/DashScopeAsrProtocolTests.swift
VoiceTypeTests/DashScopeIntegrationTests.swift  # 无 Key 时跳过
scripts/probe_dashscope.swift                   # 协议实测脚本（swift 单文件）
（修改）SettingsStore / PolishPrompt(预设) / PolishService / PolishServiceTests /
        PolishSettingsTests / AudioRecorder / AppState / DictationController /
        RecordingHUD / SettingsView / AppDependencies / README.md / README.zh-CN.md
```

---

### Task 1: KeychainStore + 润色 Key 迁移（TDD）

**Files:**
- Create: `VoiceType/Services/KeychainStore.swift`
- Modify: `VoiceType/Services/SettingsStore.swift`（polishAPIKey 改走 Keychain + 迁移函数 + v3 新配置项）
- Modify: `VoiceType/App/AppDependencies.swift`（init 首行调用迁移）
- Modify: `VoiceTypeTests/PolishSettingsTests.swift`（polishAPIKey 断言移除，改由 Keychain 测试覆盖）
- Test: `VoiceTypeTests/KeychainStoreTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/KeychainStoreTests.swift`**

```swift
import XCTest

@testable import VoiceType

final class KeychainStoreTests: XCTestCase {
    private let account = "test-keychain-store"

    override func tearDown() {
        KeychainStore.set("", account: account)  // 空值即删除
        UserDefaults.standard.removeObject(forKey: "polishAPIKey")
        KeychainStore.set("", account: "test-polish-api-key")
        super.tearDown()
    }

    func testGetMissingReturnsNil() {
        XCTAssertNil(KeychainStore.get(account))
    }

    func testSetGetRoundTrip() {
        KeychainStore.set("sk-secret-1", account: account)
        XCTAssertEqual(KeychainStore.get(account), "sk-secret-1")
    }

    func testOverwrite() {
        KeychainStore.set("v1", account: account)
        KeychainStore.set("v2", account: account)
        XCTAssertEqual(KeychainStore.get(account), "v2")
    }

    func testEmptyValueDeletes() {
        KeychainStore.set("v1", account: account)
        KeychainStore.set("", account: account)
        XCTAssertNil(KeychainStore.get(account))
    }

    func testMigrationMovesLegacyPolishKey() {
        UserDefaults.standard.set("legacy-key", forKey: "polishAPIKey")
        SettingsStore.migrateSecretsToKeychainIfNeeded(polishAccount: "test-polish-api-key")
        XCTAssertEqual(KeychainStore.get("test-polish-api-key"), "legacy-key")
        XCTAssertNil(UserDefaults.standard.string(forKey: "polishAPIKey"))
    }
}
```

- [ ] **Step 2: 运行确认编译失败**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST " | head -5`
Expected: FAIL（cannot find 'KeychainStore'）

- [ ] **Step 3: 实现 `VoiceType/Services/KeychainStore.swift`**

```swift
import Foundation
import Security

/// macOS 钥匙串薄封装（kSecClassGenericPassword）。
/// set 空字符串等价删除；service 固定为 bundle id。
enum KeychainStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.catsonkeyboard.VoiceType"
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
```

- [ ] **Step 4: 修改 `SettingsStore.swift`**

`polishAPIKey` 改为 Keychain 透传（替换原 UserDefaults 版本）：

```swift
    static var polishAPIKey: String {
        get { KeychainStore.get("polish-api-key") ?? "" }
        set { KeychainStore.set(newValue, account: "polish-api-key") }
    }
```

在 `// MARK: - 润色（v2）` 之前加 v3 配置与迁移：

```swift
    // MARK: - 识别引擎（v3）

    static var asrEngine: AsrEngine {
        get {
            defaults.string(forKey: "asrEngine").flatMap(AsrEngine.init(rawValue:)) ?? .local
        }
        set { defaults.set(newValue.rawValue, forKey: "asrEngine") }
    }

    static var dashScopeModel: String {
        get { defaults.string(forKey: "dashScopeModel") ?? "fun-asr-realtime" }
        set { defaults.set(newValue, forKey: "dashScopeModel") }
    }

    static var dashScopeAPIKey: String {
        get { KeychainStore.get("dashscope-api-key") ?? "" }
        set { KeychainStore.set(newValue, account: "dashscope-api-key") }
    }

    /// 把历史遗留的明文 Key 迁入 Keychain（App 启动时调用一次）
    static func migrateSecretsToKeychainIfNeeded(polishAccount: String = "polish-api-key") {
        if let legacy = defaults.string(forKey: "polishAPIKey"), !legacy.isEmpty {
            if KeychainStore.get(polishAccount) == nil {
                KeychainStore.set(legacy, account: polishAccount)
            }
            defaults.removeObject(forKey: "polishAPIKey")
        }
    }
```

`AsrEngine` 枚举在 Task 3 的 `DashScopeAsrProtocol.swift` 中定义；为了本任务可编译，本步先把它放进 `SettingsStore.swift` 顶部（Task 3 不再重复定义）：

```swift
enum AsrEngine: String, Codable, CaseIterable {
    case local
    case dashscope

    var label: String {
        switch self {
        case .local: return "本地 SenseVoice"
        case .dashscope: return "云端 Fun-ASR-Realtime"
        }
    }
}
```

- [ ] **Step 5: `AppDependencies.init` 首行加 `SettingsStore.migrateSecretsToKeychainIfNeeded()`**

- [ ] **Step 6: `PolishSettingsTests.swift` 调整**

`keys` 数组移除 `"polishAPIKey"`；`testDefaults` 中删除 `XCTAssertEqual(SettingsStore.polishAPIKey, "")` 一行（Key 归 Keychain 测试管）。

- [ ] **Step 7: 运行测试确认通过 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|KeychainStoreTests.*(passed|failed)|TEST " | tail -8`
Expected: 5 个用例 passed，`** TEST SUCCEEDED **`

```bash
git add VoiceType VoiceTypeTests
git commit -m "feat(v3): KeychainStore 与 API Key 迁移 (TDD)"
```

---

### Task 2: PolishService 参数兼容修正 + 服务商预设（TDD）

**Files:**
- Modify: `VoiceType/Services/PolishService.swift`（Ollama 专属参数仅本机端点携带）
- Modify: `VoiceType/Services/PolishPrompt.swift`（追加 PolishPreset）
- Test: `VoiceTypeTests/PolishServiceTests.swift`（追加用例）

- [ ] **Step 1: 在 `PolishServiceTests` 追加失败用例**

```swift
    func testRemoteEndpointOmitsOllamaParams() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let remote = PolishService(
            session: URLSession(configuration: cfg),
            configProvider: {
                PolishConfig(
                    enabled: true, baseURL: "https://api.deepseek.com/v1", apiKey: "sk-x",
                    model: "deepseek-chat", style: .clean)
            })
        stubSuccess(content: "结果文本。")
        _ = await remote.polish("嗯这是一段测试文本")
        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        let body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(request.bodyData)) as! [String: Any]
        XCTAssertNil(body["keep_alive"], "远程端点不应携带 Ollama 专属参数")
        XCTAssertNil(body["reasoning_effort"], "远程端点不应携带 Ollama 专属参数")
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
    }

    func testPresetFillsBaseURLAndModel() {
        XCTAssertEqual(PolishPreset.bailian.baseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(PolishPreset.deepseek.recommendedModel, "deepseek-chat")
        XCTAssertEqual(PolishPreset.ollama.baseURL, "http://localhost:11434/v1")
    }
```

- [ ] **Step 2: 运行确认失败**（远程用例 body 含 keep_alive → 断言失败；PolishPreset 未定义 → 编译失败）

- [ ] **Step 3: `PolishPrompt.swift` 末尾追加**

```swift
/// 润色服务商预设：仅作为设置页的一键填充器
enum PolishPreset: String, CaseIterable {
    case ollama = "本地 Ollama"
    case bailian = "阿里百炼"
    case deepseek = "DeepSeek"
    case openai = "OpenAI"

    var baseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .bailian: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    var recommendedModel: String {
        switch self {
        case .ollama: return "qwen3.5:4b-nvfp4"
        case .bailian: return "qwen-flash"
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-5-mini"
        }
    }
}
```

- [ ] **Step 4: 修改 `PolishService.swift`**

`ChatRequest` 的两个 Ollama 专属字段改为可选（Swift 合成 Codable 对 Optional 用 encodeIfPresent，nil 即不出现在 JSON）：

```swift
        let keepAlive: String?
        let reasoningEffort: String?
```

`makeChatRequest` 中构造处改为：

```swift
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
```

- [ ] **Step 5: 运行测试确认通过 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|PolishServiceTests.*(passed|failed)|TEST " | tail -8`
Expected: 13 个用例 passed（原 11 + 新 2）

```bash
git add VoiceType/Services VoiceTypeTests/PolishServiceTests.swift
git commit -m "fix(v3): Ollama 专属参数仅本机端点携带；润色服务商预设 (TDD)"
```

---

### Task 3: DashScope 协议纯逻辑（TDD）

**Files:**
- Create: `VoiceType/Services/DashScopeAsrProtocol.swift`
- Test: `VoiceTypeTests/DashScopeAsrProtocolTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/DashScopeAsrProtocolTests.swift`**

```swift
import XCTest

@testable import VoiceType

final class DashScopeAsrProtocolTests: XCTestCase {
    // MARK: - 消息构造

    func testRunTaskMessage() throws {
        let json = DashScopeAsr.runTaskMessage(taskId: "abc123", model: "fun-asr-realtime")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let header = obj["header"] as! [String: Any]
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "abc123")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        let payload = obj["payload"] as! [String: Any]
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        let params = payload["parameters"] as! [String: Any]
        XCTAssertEqual(params["format"] as? String, "pcm")
        XCTAssertEqual(params["sample_rate"] as? Int, 16000)
        XCTAssertNotNil(payload["input"])
    }

    func testFinishTaskMessage() throws {
        let json = DashScopeAsr.finishTaskMessage(taskId: "abc123")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let header = obj["header"] as! [String: Any]
        XCTAssertEqual(header["action"] as? String, "finish-task")
        XCTAssertEqual(header["task_id"] as? String, "abc123")
    }

    func testNewTaskIdIs32HexNoDash() {
        let id = DashScopeAsr.newTaskId()
        XCTAssertEqual(id.count, 32)
        XCTAssertFalse(id.contains("-"))
    }

    // MARK: - 事件解析

    func testParseTaskStarted() {
        let event = DashScopeAsr.parseEvent(
            #"{"header":{"event":"task-started","task_id":"x","attributes":{}},"payload":{}}"#)
        XCTAssertEqual(event, .taskStarted)
    }

    func testParseResultGeneratedPartial() {
        let json = #"""
        {"header":{"event":"result-generated","task_id":"x"},
         "payload":{"output":{"sentence":{"begin_time":170,"end_time":null,"text":"明天上","sentence_end":false}},"usage":null}}
        """#
        XCTAssertEqual(
            DashScopeAsr.parseEvent(json),
            .resultGenerated(DashScopeAsr.Sentence(text: "明天上", sentenceEnd: false)))
    }

    func testParseResultGeneratedFinal() {
        let json = #"""
        {"header":{"event":"result-generated","task_id":"x"},
         "payload":{"output":{"sentence":{"begin_time":170,"end_time":2100,"text":"明天上午九点开会。","sentence_end":true}}}}
        """#
        XCTAssertEqual(
            DashScopeAsr.parseEvent(json),
            .resultGenerated(DashScopeAsr.Sentence(text: "明天上午九点开会。", sentenceEnd: true)))
    }

    func testParseTaskFinishedAndFailed() {
        XCTAssertEqual(
            DashScopeAsr.parseEvent(
                #"{"header":{"event":"task-finished","task_id":"x"},"payload":{"output":{}}}"#),
            .taskFinished)
        XCTAssertEqual(
            DashScopeAsr.parseEvent(
                #"{"header":{"event":"task-failed","task_id":"x","error_code":"InvalidApiKey","error_message":"Invalid API-key provided."},"payload":{}}"#),
            .taskFailed(code: "InvalidApiKey", message: "Invalid API-key provided."))
    }

    func testParseGarbageReturnsUnknown() {
        XCTAssertEqual(DashScopeAsr.parseEvent("not json"), .unknown)
        XCTAssertEqual(DashScopeAsr.parseEvent(#"{"header":{}}"#), .unknown)
    }

    // MARK: - PCM16

    func testPcm16Conversion() {
        let data = DashScopeAsr.pcm16Data(from: [0, 1.0, -1.0, 0.5, 2.0])
        XCTAssertEqual(data.count, 10)
        let values = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 32767)
        XCTAssertEqual(values[2], -32767)
        XCTAssertEqual(values[3], 16383)
        XCTAssertEqual(values[4], 32767)  // 超界截断
    }

    // MARK: - 句子装配

    func testAssemblerPartialThenFinal() {
        var a = SentenceAssembler()
        a.ingest(.init(text: "明天", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天")
        a.ingest(.init(text: "明天上午", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天上午")
        a.ingest(.init(text: "明天上午九点开会。", sentenceEnd: true))
        a.ingest(.init(text: "记得带电脑", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天上午九点开会。记得带电脑")
        XCTAssertEqual(a.finalText, "明天上午九点开会。记得带电脑")  // 残留 partial 并入终稿
    }

    func testAssemblerEmpty() {
        let a = SentenceAssembler()
        XCTAssertEqual(a.liveText, "")
        XCTAssertEqual(a.finalText, "")
    }
}
```

- [ ] **Step 2: 运行确认编译失败**

- [ ] **Step 3: 实现 `VoiceType/Services/DashScopeAsrProtocol.swift`**

```swift
import Foundation

/// DashScope 实时 ASR WebSocket 协议的纯逻辑部分（无 I/O，可完整单测）。
/// 协议参考: https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api
enum DashScopeAsr {
    static let defaultEndpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!
    static let defaultModel = "fun-asr-realtime"

    struct Sentence: Equatable {
        var text: String
        var sentenceEnd: Bool
    }

    enum ServerEvent: Equatable {
        case taskStarted
        case resultGenerated(Sentence)
        case taskFinished
        case taskFailed(code: String, message: String)
        case unknown
    }

    static func newTaskId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func runTaskMessage(taskId: String, model: String, sampleRate: Int = 16000) -> String {
        let obj: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": ["format": "pcm", "sample_rate": sampleRate],
                "input": [String: Any](),
            ],
        ]
        return jsonString(obj)
    }

    static func finishTaskMessage(taskId: String) -> String {
        let obj: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ]
        return jsonString(obj)
    }

    static func parseEvent(_ text: String) -> ServerEvent {
        guard let data = text.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let header = obj["header"] as? [String: Any],
            let event = header["event"] as? String
        else { return .unknown }
        switch event {
        case "task-started":
            return .taskStarted
        case "task-finished":
            return .taskFinished
        case "task-failed":
            return .taskFailed(
                code: header["error_code"] as? String ?? "unknown",
                message: header["error_message"] as? String ?? "未知错误")
        case "result-generated":
            guard let payload = obj["payload"] as? [String: Any],
                let output = payload["output"] as? [String: Any],
                let sentence = output["sentence"] as? [String: Any],
                let text = sentence["text"] as? String
            else { return .unknown }
            return .resultGenerated(
                Sentence(text: text, sentenceEnd: sentence["sentence_end"] as? Bool ?? false))
        default:
            return .unknown
        }
    }

    /// Float32 [-1,1] → 16bit PCM 小端
    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 增量识别结果装配：已定稿句子 + 当前 partial → 实时文本 / 终稿
struct SentenceAssembler {
    private(set) var finalized: [String] = []
    private(set) var partial: String = ""

    mutating func ingest(_ sentence: DashScopeAsr.Sentence) {
        if sentence.sentenceEnd {
            if !sentence.text.isEmpty { finalized.append(sentence.text) }
            partial = ""
        } else {
            partial = sentence.text
        }
    }

    var liveText: String {
        (finalized + (partial.isEmpty ? [] : [partial])).joined()
    }

    /// finish 时残留的 partial 并入终稿（服务端可能不给最后一句发 sentence_end）
    var finalText: String { liveText }
}
```

- [ ] **Step 4: 运行测试确认通过 + Commit**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|DashScopeAsrProtocolTests.*(passed|failed)|TEST " | tail -13`
Expected: 11 个用例 passed

```bash
git add VoiceType/Services/DashScopeAsrProtocol.swift VoiceTypeTests/DashScopeAsrProtocolTests.swift
git commit -m "feat(v3): DashScope ASR 协议纯逻辑与句子装配器 (TDD)"
```

---

### Task 4: DashScopeAsrSession + probe 脚本 + 集成测试

**Files:**
- Create: `VoiceType/Services/DashScopeAsrSession.swift`
- Create: `scripts/probe_dashscope.swift`
- Test: `VoiceTypeTests/DashScopeIntegrationTests.swift`（无 Key 自动跳过）

- [ ] **Step 1: 实现 `VoiceType/Services/DashScopeAsrSession.swift`**

```swift
import Foundation

enum DashScopeError: LocalizedError {
    case notConfigured
    case connectFailed(String)
    case taskFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 DashScope API Key"
        case .connectFailed(let msg): return "云端连接失败：\(msg)"
        case .taskFailed(let msg): return "云端识别失败：\(msg)"
        case .timeout: return "云端识别超时"
        }
    }
}

/// Fun-ASR-Realtime WebSocket 会话（一次听写一个实例）。
/// 生命周期：start() → send(samples)... → finish() -> 终稿；任何失败由调用方回退本地。
/// 音频在 task-started 之前自动缓冲，之后按 ~100ms 帧推送。
final class DashScopeAsrSession: NSObject, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let taskId = DashScopeAsr.newTaskId()
    private var socket: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var assembler = SentenceAssembler()
    private var pending: [Float] = []
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<String, Error>?

    private static let frameSamples = 1600  // 100ms @16kHz

    init(apiKey: String, model: String, endpoint: URL = DashScopeAsr.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    /// 建连 + run-task，等待 task-started（5 秒超时）
    func start() async throws {
        guard !apiKey.isEmpty else { throw DashScopeError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiveLoop()

        let runTask = DashScopeAsr.runTaskMessage(taskId: taskId, model: model)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            startedContinuation = cont
            lock.unlock()
            socket.send(.string(runTask)) { [weak self] error in
                if let error {
                    self?.resumeStarted(.failure(DashScopeError.connectFailed(error.localizedDescription)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.resumeStarted(.failure(DashScopeError.timeout))
            }
        }
    }

    /// 追加音频；内部攒满 ~100ms 且任务已启动时发送二进制帧
    func send(samples: [Float]) {
        lock.lock()
        pending.append(contentsOf: samples)
        var frame: [Float]?
        if started && pending.count >= Self.frameSamples {
            frame = pending
            pending = []
        }
        lock.unlock()
        if let frame {
            socket?.send(.data(DashScopeAsr.pcm16Data(from: frame))) { _ in }
        }
    }

    /// 冲刷缓冲 + finish-task，等待 task-finished（15 秒超时），返回终稿
    func finish() async throws -> String {
        lock.lock()
        let rest = pending
        pending = []
        lock.unlock()
        if !rest.isEmpty {
            socket?.send(.data(DashScopeAsr.pcm16Data(from: rest))) { _ in }
        }
        let message = DashScopeAsr.finishTaskMessage(taskId: taskId)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            finishContinuation = cont
            lock.unlock()
            socket?.send(.string(message)) { [weak self] error in
                if let error {
                    self?.resumeFinish(.failure(DashScopeError.connectFailed(error.localizedDescription)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.resumeFinish(.failure(DashScopeError.timeout))
            }
        }
    }

    /// 放弃会话（回退/取消路径）
    func cancel() {
        socket?.cancel(with: .goingAway, reason: nil)
        failAll(CancellationError())
    }

    // MARK: - 私有

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failAll(DashScopeError.connectFailed(error.localizedDescription))
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(DashScopeAsr.parseEvent(text))
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ event: DashScopeAsr.ServerEvent) {
        switch event {
        case .taskStarted:
            lock.lock()
            started = true
            lock.unlock()
            resumeStarted(.success(()))
            send(samples: [])  // 触发已缓冲音频的冲刷判断
        case .resultGenerated(let sentence):
            lock.lock()
            assembler.ingest(sentence)
            let live = assembler.liveText
            lock.unlock()
            onPartial?(live)
        case .taskFinished:
            lock.lock()
            let final = assembler.finalText
            lock.unlock()
            resumeFinish(.success(final))
            socket?.cancel(with: .normalClosure, reason: nil)
        case .taskFailed(let code, let message):
            failAll(DashScopeError.taskFailed("\(code): \(message)"))
        case .unknown:
            break
        }
    }

    /// 恢复 continuation（exactly-once：取出即置 nil）
    private func resumeStarted(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = startedContinuation
        startedContinuation = nil
        lock.unlock()
        switch result {
        case .success: cont?.resume()
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func resumeFinish(_ result: Result<String, Error>) {
        lock.lock()
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()
        switch result {
        case .success(let text): cont?.resume(returning: text)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        resumeStarted(.failure(error))
        resumeFinish(.failure(error))
    }
}
```

注意 `send(samples: [])` 在 taskStarted 后的冲刷：`send` 中 `started && pending.count >= frameSamples` 的判断对空参调用同样生效，若缓冲不足 100ms 则等下一 chunk，无需特殊处理。

- [ ] **Step 2: 写 `VoiceTypeTests/DashScopeIntegrationTests.swift`**

```swift
import XCTest

@testable import VoiceType

/// 真实端点集成测试：需要 DASHSCOPE_API_KEY 环境变量或 Keychain 中已存 Key，否则跳过。
final class DashScopeIntegrationTests: XCTestCase {
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !env.isEmpty {
            return env
        }
        return KeychainStore.get("dashscope-api-key") ?? ""
    }

    func testRealtimeTranscription() async throws {
        try XCTSkipUnless(!Self.apiKey.isEmpty, "无 DASHSCOPE_API_KEY，跳过云端集成测试")
        let wav = AsrServiceTests.testWav
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wav.path), "测试音频不存在")

        let samples = try AudioFileDecoder.decode16kMono(url: wav)
        let session = DashScopeAsrSession(apiKey: Self.apiKey, model: DashScopeAsr.defaultModel)
        let partialFired = expectation(description: "partial 至少触发一次")
        partialFired.assertForOverFulfill = false
        session.onPartial = { _ in partialFired.fulfill() }

        try await session.start()
        var i = 0
        while i < samples.count {
            let end = min(i + 1600, samples.count)
            session.send(samples: Array(samples[i..<end]))
            i = end
        }
        let text = try await session.finish()
        print("DashScope 终稿: \(text)")
        await fulfillment(of: [partialFired], timeout: 1)
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "云端应识别出中文，实际: \(text)")
    }

    func testInvalidKeyFailsFast() async throws {
        try XCTSkipUnless(!Self.apiKey.isEmpty, "无网络凭据环境，跳过")
        let session = DashScopeAsrSession(apiKey: "sk-invalid-key", model: DashScopeAsr.defaultModel)
        do {
            try await session.start()
            XCTFail("无效 Key 应失败")
        } catch {}
    }
}
```

- [ ] **Step 3: 写 `scripts/probe_dashscope.swift`**（协议实测工具，打印原始服务端事件）

```swift
#!/usr/bin/env swift
// DashScope Fun-ASR-Realtime 协议探针：
//   DASHSCOPE_API_KEY=sk-xxx swift scripts/probe_dashscope.swift [wav文件路径]
// 打印全部服务端原始 JSON 事件，用于核对解析器字段。
import AVFoundation
import Foundation

let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] ?? ""
guard !apiKey.isEmpty else {
    print("用法: DASHSCOPE_API_KEY=sk-xxx swift scripts/probe_dashscope.swift [wav]")
    exit(1)
}
let wavPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/.cache/modelscope/hub/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch/asr_example_hotword.wav").expandingTildeInPath

// wav → 16k mono Float32
func decode16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: dst)!
    var result: [Float] = []
    var eof = false
    let input: AVAudioConverterInputBlock = { _, status in
        if eof { status.pointee = .endOfStream; return nil }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        try? file.read(into: buf)
        if buf.frameLength == 0 { eof = true; status.pointee = .endOfStream; return nil }
        status.pointee = .haveData
        return buf
    }
    while true {
        let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192)!
        var err: NSError?
        let st = converter.convert(to: out, error: &err, withInputFrom: input)
        if out.frameLength > 0 {
            result.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        if st == .endOfStream || st == .error { break }
    }
    return result
}

func pcm16(_ samples: ArraySlice<Float>) -> Data {
    var d = Data(capacity: samples.count * 2)
    for s in samples {
        let v = Int16(max(-1, min(1, s)) * 32767)
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

let samples = try decode16k(wavPath)
print("音频: \(samples.count) samples (\(Double(samples.count)/16000)s)")

let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!)
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
let socket = URLSession.shared.webSocketTask(with: request)
socket.resume()

let done = DispatchSemaphore(value: 0)
func receive() {
    socket.receive { result in
        switch result {
        case .failure(let e):
            print("❌ 接收错误: \(e)")
            done.signal()
        case .success(.string(let text)):
            print("<<< \(text)")
            if text.contains("task-finished") || text.contains("task-failed") { done.signal() } else { receive() }
        case .success:
            receive()
        }
    }
}
receive()

let runTask = """
{"header":{"action":"run-task","task_id":"\(taskId)","streaming":"duplex"},"payload":{"task_group":"audio","task":"asr","function":"recognition","model":"fun-asr-realtime","parameters":{"format":"pcm","sample_rate":16000},"input":{}}}
"""
print(">>> run-task")
socket.send(.string(runTask)) { if let e = $0 { print("❌ \(e)") } }
Thread.sleep(forTimeInterval: 1)

var i = 0
while i < samples.count {
    let end = min(i + 1600, samples.count)
    socket.send(.data(pcm16(samples[i..<end]))) { if let e = $0 { print("❌ \(e)") } }
    i = end
    Thread.sleep(forTimeInterval: 0.02)
}
print(">>> finish-task")
let finishTask = """
{"header":{"action":"finish-task","task_id":"\(taskId)","streaming":"duplex"},"payload":{"input":{}}}
"""
socket.send(.string(finishTask)) { if let e = $0 { print("❌ \(e)") } }

_ = done.wait(timeout: .now() + 30)
socket.cancel(with: .normalClosure, reason: nil)
print("完成")
```

- [ ] **Step 4: 构建 + 全量测试（集成用例应显示 skipped）+ Commit**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|skipped|Executed .* tests|TEST " | tail -8`
Expected: `** TEST SUCCEEDED **`，DashScopeIntegrationTests 2 个用例 skipped（提示无 Key）

```bash
git add VoiceType/Services/DashScopeAsrSession.swift VoiceTypeTests/DashScopeIntegrationTests.swift scripts/probe_dashscope.swift
git commit -m "feat(v3): DashScope WebSocket 会话 + 协议探针 + 集成测试(无Key跳过)"
```

---

### Task 5: 听写管线云端分流

**Files:**
- Modify: `VoiceType/Services/AudioRecorder.swift`（onChunk）
- Modify: `VoiceType/App/AppState.swift`（partialText）
- Modify: `VoiceType/Services/DictationController.swift`（分流 + 回退）
- Modify: `VoiceType/UI/RecordingHUD.swift`（实时上屏 + 面板加宽）

- [ ] **Step 1: `AudioRecorder` 加 chunk 回调**

属性区加：

```swift
    /// 转换后的 16k chunk 实时回调（主线程派发，云端推流用）
    var onChunk: (([Float]) -> Void)?
```

`process(buffer:)` 尾部的主线程派发改为（合并 level 与 chunk）：

```swift
        let chunkArray = Array(chunk)
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
            self?.onChunk?(chunkArray)
        }
```

（原 `DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }` 删除。注意 `chunkArray` 须在 lock 外从 `UnsafeBufferPointer` 拷贝——直接用现有 `chunk` 变量即可，它在字节缓冲有效期内。将 `let chunkArray = Array(chunk)` 放在 `lock.lock()` 之前。）

- [ ] **Step 2: `AppState` 加字段**

```swift
    /// 云端识别的实时中间结果（仅云端引擎录音阶段非空）
    var partialText: String?
```

- [ ] **Step 3: `DictationController` 分流**

属性区加：

```swift
    private var cloudSession: DashScopeAsrSession?
```

`startRecording()` 整体替换为：

```swift
    private func startRecording() {
        let engine = SettingsStore.asrEngine
        switch engine {
        case .local:
            state.refreshModelsReady()
            guard state.modelsReady else {
                state.phase = .error(AsrError.modelMissing.localizedDescription)
                HUDController.shared.flash("模型未安装，请查看设置", state: state)
                return
            }
        case .dashscope:
            guard !SettingsStore.dashScopeAPIKey.isEmpty else {
                state.phase = .error(DashScopeError.notConfigured.localizedDescription)
                HUDController.shared.flash("请在设置 → 识别 中填写 DashScope API Key", state: state)
                return
            }
        }
        Task {
            guard await AudioRecorder.requestPermission() else {
                state.phase = .error("麦克风未授权")
                HUDController.shared.flash("麦克风未授权，请在系统设置中允许", state: state)
                return
            }
            do {
                if engine == .dashscope { setupCloudSession() }
                recorder.onLevel = { [weak self] level in
                    self?.state.micLevel = level
                }
                recorder.onChunk = { [weak self] chunk in
                    self?.cloudSession?.send(samples: chunk)
                }
                try recorder.start()
                state.phase = .recording
                HUDController.shared.show(state: state)
                capTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.maxRecordingSeconds, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in await self?.finishRecording() }
                }
            } catch {
                cloudSession?.cancel()
                cloudSession = nil
                state.phase = .error(error.localizedDescription)
                HUDController.shared.flash(error.localizedDescription, state: state)
            }
        }
    }

    /// 并行建立云端会话；建连失败仅使本次云端不可用（finish 时走本地回退）
    private func setupCloudSession() {
        let session = DashScopeAsrSession(
            apiKey: SettingsStore.dashScopeAPIKey, model: SettingsStore.dashScopeModel)
        session.onPartial = { [weak self] text in
            Task { @MainActor in self?.state.partialText = text }
        }
        cloudSession = session
        Task { [weak self, session] in
            do {
                try await session.start()
            } catch {
                await MainActor.run {
                    // 仅当仍是当前会话时清除（避免竞态清掉下一次的会话）
                    if self?.cloudSession === session { self?.cloudSession = nil }
                }
            }
        }
    }
```

`finishRecording()` 整体替换为：

```swift
    private func finishRecording() async {
        guard state.phase == .recording else { return }
        capTimer?.invalidate()
        capTimer = nil
        let samples = recorder.stop()
        recorder.onChunk = nil
        let session = cloudSession
        cloudSession = nil
        state.partialText = nil

        let duration = Double(samples.count) / 16000.0
        guard duration >= Self.minRecordingSeconds else {
            session?.cancel()
            state.phase = .idle
            HUDController.shared.hide()
            return
        }
        state.phase = .transcribing
        do {
            var cloudDegraded = false
            var text: String
            if let session {
                do {
                    text = try await session.finish()
                } catch {
                    session.cancel()
                    cloudDegraded = true
                    text = try await asr.transcribe(samples: samples)
                }
            } else {
                if SettingsStore.asrEngine == .dashscope { cloudDegraded = true }
                text = try await asr.transcribe(samples: samples)
            }
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
                if cloudDegraded {
                    HUDController.shared.flash("云端不可用，已用本地识别", state: state)
                } else if polishDegraded {
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
        } catch {
            state.phase = .error(error.localizedDescription)
            HUDController.shared.flash("识别失败：\(error.localizedDescription)", state: state)
        }
    }
```

- [ ] **Step 4: HUD 实时上屏**

`HUDController.show` 中 `contentRect` 与定位尺寸改为 320×96：

```swift
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
```

`RecordingHUDView` 的 `.recording` case 改为（外层结构不变，仅该 case）：

```swift
                case .recording:
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(.red)
                            LevelBarsView(level: state.micLevel)
                            Text("录音中")
                                .foregroundStyle(.secondary)
                        }
                        if let partial = state.partialText, !partial.isEmpty {
                            Text(partial)
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .truncationMode(.head)  // 保留最新内容（尾部）
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
```

视图末尾 `.frame(width: 240, height: 56)` 改为 `.frame(width: 320)`。

- [ ] **Step 5: 全量测试 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|Executed .* tests|TEST " | tail -3`
Expected: `** TEST SUCCEEDED **`

```bash
git add VoiceType
git commit -m "feat(v3): 听写管线云端分流（实时上屏/自动回退/录音门槛按引擎）"
```

---

### Task 6: 设置「识别」Tab + 润色预设 UI

**Files:**
- Modify: `VoiceType/UI/SettingsView.swift`

- [ ] **Step 1: TabView 在通用与润色之间插入**

```swift
            RecognitionSettingsView()
                .tabItem { Label("识别", systemImage: "waveform") }
```

- [ ] **Step 2: 文件末尾追加 `RecognitionSettingsView`**

```swift
private struct RecognitionSettingsView: View {
    @State private var engine = SettingsStore.asrEngine
    @State private var apiKey = SettingsStore.dashScopeAPIKey
    @State private var model = SettingsStore.dashScopeModel
    @State private var testing = false
    @State private var testOK = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("识别引擎") {
                Picker("引擎", selection: $engine) {
                    ForEach(AsrEngine.allCases, id: \.self) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: engine) { _, newValue in
                    SettingsStore.asrEngine = newValue
                }
                if engine == .dashscope {
                    Text("云端模式下，录音音频将实时发送至阿里云百炼进行识别；失败时自动回退本地引擎。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if engine == .dashscope {
                Section("阿里百炼 (DashScope)") {
                    SecureField("API Key（存储于钥匙串）", text: $apiKey)
                        .onChange(of: apiKey) { _, v in SettingsStore.dashScopeAPIKey = v }
                    TextField("模型", text: $model)
                        .onChange(of: model) { _, v in SettingsStore.dashScopeModel = v }
                    Button(testing ? "测试中…" : "测试连接") { runTest() }
                        .disabled(testing || apiKey.isEmpty)
                    if let testResult {
                        Label(
                            testResult,
                            systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(testOK ? .green : .red)
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 用 0.5 秒静音走完整协议验证 Key 与连通性
    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let session = DashScopeAsrSession(apiKey: apiKey, model: model)
            do {
                try await session.start()
                session.send(samples: [Float](repeating: 0, count: 8000))
                _ = try await session.finish()
                testOK = true
                testResult = "连接成功，Key 有效"
            } catch {
                session.cancel()
                testOK = false
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}
```

- [ ] **Step 3: `PolishSettingsView` 服务 Section 顶部加预设菜单**

在 `TextField("服务地址", ...)` 之前插入：

```swift
                Menu("服务商预设") {
                    ForEach(PolishPreset.allCases, id: \.self) { preset in
                        Button("\(preset.rawValue)（\(preset.recommendedModel)）") {
                            baseURL = preset.baseURL
                            SettingsStore.polishBaseURL = preset.baseURL
                            model = preset.recommendedModel
                            SettingsStore.polishModel = preset.recommendedModel
                        }
                    }
                }
```

- [ ] **Step 4: 全量测试 + Commit**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST " | tail -3`
Expected: `** TEST SUCCEEDED **`

```bash
git add VoiceType/UI/SettingsView.swift
git commit -m "feat(v3): 设置识别 Tab（引擎/Key/测试连接）+ 润色服务商预设"
```

---

### Task 7: README 更新 + 构建交付

**Files:**
- Modify: `README.md`、`README.zh-CN.md`

- [ ] **Step 1: `README.md` 修改**

- 首段 "entirely on-device" 改为 "on-device by default"
- Features 列表加：

```markdown
- **Cloud ASR (v3, optional)**: switch to Alibaba Cloud Model Studio's Fun-ASR-Realtime for streaming recognition — live partial results in the HUD while you speak, near-instant final text on stop, automatic fallback to the local engine on any failure. API key stored in the macOS Keychain. Note: cloud mode sends audio to Alibaba Cloud
```

- Performance 段落的 "No network calls — audio and text never leave your Mac." 改为 "Local mode makes no network calls — audio and text never leave your Mac. Cloud ASR and cloud polishing are explicit opt-ins."
- Smart polishing 段落末尾追加一句：

```markdown
Provider presets (Ollama / Alibaba Model Studio / DeepSeek / OpenAI) fill in the endpoint and a recommended model with one click.
```

- [ ] **Step 2: `README.zh-CN.md` 对应修改**

- 功能列表加：

```markdown
- **云端识别（v3，可选）**：可切换到阿里云百炼 Fun-ASR-Realtime 流式识别——说话时 HUD 实时显示中间结果，停止后终稿几乎立即产出；任何失败自动回退本地引擎。API Key 存 macOS 钥匙串。注意：云端模式音频会发送至阿里云
```

- 简介中"本地推理，无网络依赖"改为"默认本地推理；云端识别与云端润色为显式可选项"
- 智能润色一节追加："设置内置服务商预设（本地 Ollama / 阿里百炼 / DeepSeek / OpenAI），一键填充地址与推荐模型。"

- [ ] **Step 3: 全量测试 + 构建安装 + 最终提交**

```bash
xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test
./scripts/install.sh
git add -A
git commit -m "feat(v3): 云端 ASR 完成（README 与交付）"
```

- [ ] **Step 4: 交付给用户的验收清单（写进交付说明，不自动执行）**

1. 百炼控制台开通 Fun-ASR 并获取 API Key
2. 协议实测：`DASHSCOPE_API_KEY=sk-xxx swift scripts/probe_dashscope.swift`——核对打印的事件字段与解析器一致（不一致则报回修正）
3. 集成测试：`DASHSCOPE_API_KEY=sk-xxx xcodebuild ... test -only-testing:VoiceTypeTests/DashScopeIntegrationTests`
4. 设置 → 识别：切云端引擎、填 Key、「测试连接」应绿
5. ⌥Space 听写：HUD 应实时显示识别文本，停止后终稿注入光标
6. 断网/填错 Key 再听写：应自动回退本地识别并有 HUD 提示
7. 润色预设：切到"阿里百炼"填 Key，跑一次听写验证云端润色

---

## 与 spec 的对照（自查结论）

- 云端引擎 + 真流式 + 实时上屏 → Task 4/5；自动回退 → Task 5 finishRecording
- Keychain + 润色 Key 迁移 → Task 1；DashScope Key 只存 Keychain → Task 1/6
- Ollama 专属参数兼容修正 → Task 2（spec §5.2）
- 服务商预设 → Task 2（数据）+ Task 6（UI）
- 录音门槛按引擎 → Task 5 startRecording；文件转写不动 → 无涉及改动
- probe 脚本 → Task 4；集成测试无 Key 跳过 → Task 4
- HUD partial 只进 HUD 不进输入框 → Task 5（注入仍一次性）
- 隐私文案 → Task 6（设置提示）+ Task 7（README）
