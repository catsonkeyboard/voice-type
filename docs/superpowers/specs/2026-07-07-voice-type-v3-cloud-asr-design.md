# VoiceType v3 设计文档：云端 ASR（Fun-ASR-Realtime）+ 润色服务商预设

- 日期：2026-07-07
- 状态：待用户审阅
- 前置：v1 本地转写、v2 智能润色已交付，见同目录既有 spec

## 1. 背景与目标

v1/v2 全链路本地推理。v3 引入**可选的云端识别引擎**——阿里百炼 Fun-ASR-Realtime（WebSocket 实时流式），并补齐润色的外部 LLM API 易用性（服务商预设）。本地仍是默认，云端是显式 opt-in。

成功标准：

1. 设置中切到云端引擎后：录音时 HUD **实时显示识别中间结果**，停止后终稿几乎立即产出（无本地推理等待）
2. 云端任何失败（断网/Key 无效/超时）**自动回退本地引擎重识别**，听写永不失败（本地模型在位时）
3. 本地引擎行为与 v2 完全一致，零回归
4. 润色可一键切换到百炼/DeepSeek/OpenAI 等外部 API（预设填充地址+推荐模型，仅需补 Key）
5. API Key 存 macOS Keychain，不落明文

## 2. 云端 ASR 协议（已核实要点）

- 端点：`wss://dashscope.aliyuncs.com/api-ws/v1/inference/`（北京地域通用端点）
- 握手头：`Authorization: Bearer <DashScope API Key>`
- 模型：`fun-asr-realtime`（设置中可改，兼容 paraformer-realtime 系列同协议模型）
- 消息流：
  1. 客户端发 `run-task`（JSON 文本帧）：`header{action:"run-task", task_id:<32位无横线uuid>, streaming:"duplex"}`，`payload{task_group:"audio", task:"asr", function:"recognition", model, parameters{format:"pcm", sample_rate:16000}, input:{}}`
  2. 服务端回 `task-started`
  3. 客户端持续发**二进制音频帧**（16kHz 单声道 PCM16 小端，约 100ms/帧 ≈ 3200 字节）
  4. 服务端持续回 `result-generated`：`payload.output.sentence{text, begin_time, end_time, sentence_end(bool), ...}`——`sentence_end=false` 为增量 partial（同句反复刷新），`true` 为该句定稿
  5. 客户端发 `finish-task` → 服务端回 `task-finished`（或任意阶段 `task-failed`：`header.error_code/error_message`）
- **实施第一步是 probe 脚本**：对真实端点跑通完整握手并抓取真实事件 JSON，若字段与上述有出入，以实测为准修正解析器（文档页为动态加载，细节 schema 以实测兜底）

## 3. 架构

### 3.1 数据流

```
【本地引擎（默认，行为不变）】
录音累积 samples ─停止→ AsrService.transcribe → 热词纠正 → 润色 → 注入

【云端引擎】
AudioRecorder ──onChunk（16k Float32 实时）──→ DashScopeAsrSession
    │                                            ├─ WebSocket 推流（PCM16 二进制帧）
    │                                            └─ onPartial → AppState.partialText → HUD 实时上屏
    └── samples 全程照常累积（回退保底）
停止 → session.finish() ──成功──→ 终稿 ─→ 热词纠正 → 润色 → 注入
                └──任何失败──→ AsrService.transcribe(samples) 本地回退
                                    └─ 本地模型也缺 → 报错
```

### 3.2 新增组件（纯逻辑与 I/O 壳分离）

**`DashScopeAsrProtocol`**（enum + 纯函数 + 状态机，无 I/O，可完整单测）：

```swift
enum DashScopeAsrProtocol {
    static func runTaskMessage(taskId: String, model: String, sampleRate: Int) -> String  // JSON
    static func finishTaskMessage(taskId: String) -> String
    static func parseEvent(_ json: String) -> ServerEvent   // .taskStarted / .resultGenerated(Sentence) / .taskFinished / .taskFailed(code,message) / .unknown
    static func pcm16Data(from samples: [Float]) -> Data    // Float32 [-1,1] → Int16 LE
}

struct SentenceAssembler {   // 状态机：增量事件 → 实时文本 + 终稿
    mutating func ingest(_ sentence: Sentence)
    var liveText: String     // 已定稿句子 + 当前 partial（HUD 用）
    var finalText: String    // 全部定稿句子拼接（finish 后取）
}
```

**`DashScopeAsrSession`**（`URLSessionWebSocketTask` 薄壳，@unchecked Sendable）：

```swift
final class DashScopeAsrSession {
    init(apiKey: String, model: String, endpoint: URL)
    var onPartial: (@Sendable (String) -> Void)?
    func start() async throws            // 建连 + run-task + 等 task-started（超时 5s）
    func send(samples: [Float])          // 内部缓冲，攒满 ~100ms 发一帧
    func finish() async throws -> String // finish-task → 等 task-finished（超时 15s）→ SentenceAssembler.finalText
    func cancel()                        // 放弃（回退路径中调用）
}
```

### 3.3 既有组件改动

| 组件 | 改动 |
|---|---|
| `AudioRecorder` | 新增 `onChunk: (([Float]) -> Void)?`，在 tap 转换后同步回调（主线程派发）；samples 累积逻辑不变 |
| `DictationController` | 按 `SettingsStore.asrEngine` 分流。云端路径：start 时并行建立 session（建连失败不阻断录音，标记本次云端不可用）；chunk 转发；finish 时 `session.finish()`，任何 throw → 本地回退 + HUD 提示"云端不可用，已用本地识别" |
| `AppState` | 新增 `partialText: String?`（仅云端录音阶段非空） |
| `RecordingHUD` | 录音中 `partialText` 非空时显示实时文本（宽度 320，最多 2 行，尾部截断）；无 partial 时维持现状 |
| 录音门槛 | `modelsReady` 仅在本地引擎时作为录音前置条件；云端引擎无本地模型也可听写（回退不可用，失败则报错） |
| 文件转写 | 不变，始终走本地引擎（云端按时长计费，长文件场景不适配；本地模型缺失时文件转写不可用，与 v1 一致） |

### 3.4 引擎与 Key 配置

```swift
enum AsrEngine: String, Codable, CaseIterable { case local, dashscope }

// SettingsStore 新增
static var asrEngine: AsrEngine          // 默认 .local（UserDefaults）
static var dashScopeModel: String        // 默认 "fun-asr-realtime"（UserDefaults）
// Key 一律走 KeychainStore（见 §4）
```

## 4. KeychainStore 与 Key 迁移

新增 `KeychainStore`（Security 框架，`kSecClassGenericPassword`，service 固定为 bundle id，account 区分用途）：

```swift
enum KeychainStore {
    static func get(_ account: String) -> String?
    static func set(_ value: String, account: String)   // 空字符串即删除
}
// account: "dashscope-api-key" / "polish-api-key"
```

- DashScope Key 只存 Keychain
- **润色 API Key 从 UserDefaults 迁移到 Keychain**：App 启动时若 UserDefaults 存在旧值 → 写入 Keychain 并删除明文；`SettingsStore.polishAPIKey` 的存取改为透传 KeychainStore
- 单测使用独立 account 前缀（`test-`），tearDown 清理

## 5. 润色：服务商预设 + 参数兼容性修正

### 5.1 预设

「润色」Tab 服务地址上方加预设下拉（`Menu`），选中即填充地址与推荐模型（Key 不动，用户自补）：

| 预设 | baseURL | 推荐模型 |
|---|---|---|
| 本地 Ollama（默认） | `http://localhost:11434/v1` | `qwen3.5:4b-nvfp4` |
| 阿里百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-flash` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/v1` | `gpt-5-mini` |

预设只是填充器，不引入"配置档案"概念（YAGNI）。

### 5.2 参数兼容性修正（现存 bug）

现在润色请求体总是带 `keep_alive` 与 `reasoning_effort: "none"`——这两个是 Ollama 专属参数，OpenAI 对未知/非法参数会返回 400。修正：**仅当端点 host 为 `localhost` 或 `127.0.0.1` 时携带这两个参数**。单测覆盖两种 host 的请求体差异。

## 6. 设置界面

新增「识别」Tab（放在通用与润色之间）：

- 引擎 Picker：本地 SenseVoice / 云端 Fun-ASR-Realtime（副文案注明"音频将发送至阿里云"）
- DashScope API Key（SecureField → Keychain）
- 模型名 TextField（默认 `fun-asr-realtime`）
- 「测试连接」：用 0.5 秒静音走完整协议（run-task → 推帧 → finish-task），报成功/具体错误（Key 无效/网络不通）

## 7. 错误处理总表

| 场景 | 行为 |
|---|---|
| 云端建连失败 / task-failed / Key 无效 | 本次转本地识别；HUD"云端不可用，已用本地识别"；本地模型缺失 → HUD 报错 |
| 推流中 WebSocket 断开 | 同上（samples 全程在手，无损回退） |
| `finish()` 超时 15 秒 | 同上 |
| 云端返回空文本 | 视为静音：静默取消，不注入（与本地一致） |
| Keychain 读不到 Key 而引擎选了云端 | 录音前 HUD 提示去设置填 Key，不进入录音 |
| 本地引擎路径 | 与 v2 完全一致，不受影响 |

## 8. 测试策略

- **单元测试**：
  - `DashScopeAsrProtocol`：run-task/finish-task JSON 字段断言；`parseEvent` 对四类事件样例 JSON 的解析（样例以 probe 实测抓取为准）；PCM16 转换（幅值/截断/字节序）
  - `SentenceAssembler`：partial 反复刷新→定稿、多句、finish 时残留 partial 的归并
  - `KeychainStore`：读写删往返（测试专用 account）
  - `PolishService`：localhost 与非 localhost 端点的请求体参数差异（携带/不携带 Ollama 专属参数）
- **集成测试**（无 Key 时 XCTSkip，Key 取 `KeychainStore` 或环境变量 `DASHSCOPE_API_KEY`）：真实端点推送本地测试 wav（分帧模拟实时），断言终稿含中文且 partial 回调至少触发一次
- **人工验收**：云端引擎实时上屏体验；拔网线验证自动回退；测试连接按钮
- 回归：v2 全部 35 个用例保持绿

## 9. 隐私与文档

- README（中英）："100% offline" 表述改为 "offline by default"；新增云端引擎说明：显式选用后音频实时发送至阿里云百炼，Key 存 Keychain
- 设置界面引擎选项旁注明数据出境事实

## 10. 范围

### v3 交付

1. `DashScopeAsrProtocol` + `SentenceAssembler` + `DashScopeAsrSession`
2. 引擎切换 + 听写管线云端分流 + 自动回退
3. HUD 实时上屏（partialText）
4. `KeychainStore` + 润色 Key 迁移
5. 设置「识别」Tab + 润色服务商预设 + Ollama 专属参数兼容性修正
6. probe 脚本（`scripts/probe_dashscope.sh` 或 swift 单文件，开发期用）
7. README 中英更新

### 明确不做（YAGNI）

- 文件转写走云端、其他云厂商 ASR（引擎枚举已留扩展位）、注入过程中的逐字实时上屏（partial 只进 HUD 不进目标输入框）、多地域端点切换、润色多配置档案、用量/计费显示
