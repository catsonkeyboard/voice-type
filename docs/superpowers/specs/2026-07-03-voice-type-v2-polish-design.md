# VoiceType v2 设计文档：智能润色（类 Typeless）

- 日期：2026-07-03
- 状态：待用户审阅
- 前置：v1 已交付（SenseVoice 本地转写 + 快捷键听写到光标），见 `2026-07-03-voice-type-design.md`

## 1. 背景与目标

v1 输出的是"逐字转写"：口头禅、说错重说、口语碎片会原样打进文档。v2 在 ASR 之后加一层本地 LLM 语义重写，实现类 Typeless 的体验——说得随意，出来的是精心打出来的书面文字。

四项核心能力（验收金标）：

1. **口头禅过滤**：自动删除"呃、嗯、那个、就是说、然后那个"等填充词
2. **自我纠正识别**：口述"明天下午……呃不对，是明天上午九点开会" → 输出"明天上午九点开会。"
3. **口语碎片 → 连贯书面语**：顺语序、补标点、合并断续短句，但不改变意思、不添加原话没有的信息
4. **自动格式化列表**：口述"第一……第二……第三……" → 输出 Markdown 编号/项目符号列表

成功标准：

- 快捷键听写全链路（说完 → 文字出现在光标处）延迟 ≤ 3 秒（10 秒内的口述）
- 润色引擎不可用时**永不阻断输出**：自动降级为原始转写
- 全程本地推理，无数据出机器

## 2. 引擎选型

| 方案 | 结论 |
|---|---|
| **Ollama HTTP（采用）** | 本机已安装且常驻（`localhost:11434`）。App 通过 OpenAI 兼容协议 `/v1/chat/completions` 调用，零新增运行时；未来切云端 API（DeepSeek/Qwen/Claude 等）只需改 baseURL+key，同一客户端代码 |
| 内嵌 llama.cpp / MLX | ❌ 自行管理模型分发与内存，工程量大，Ollama 已就位无必要 |
| macOS FoundationModels（苹果端侧模型） | ❌ 约 3B 模型中文重写质量不可控，模型不可替换 |

**模型**：默认 **`qwen3.5:4b-nvfp4`**（4.0GB，用户确认的选择）。选型依据：本机 Ollama 0.30 在 M5 级 Apple Silicon 上启用了 **MLX 推理后端**（[官方公告](https://ollama.com/blog/mlx)），`nvfp4` 后缀即 MLX 引擎的 4-bit 浮点量化格式（已在本机用 `--mlx-engine` 运行时参数实证），同体积下保真度优于标准 int4；4B 通用 instruct 满足润色类改写任务，且符合用户 ≤5GB 的内存预算。

**模型由用户自行下载**（`ollama pull qwen3.5:4b-nvfp4`），App 与脚本不自动拉取：设置页检测到模型缺失时展示可复制的 pull 命令；集成测试在模型缺失时自动跳过。质量闸门：模型就位后跑金标集成用例（口头禅/自我纠正/碎片连贯化/列表化），不达标的升级路径为 `4b-mxfp8`（5.6GB）或 `9b-nvfp4`（8.9GB），在设置页改模型名即可。

**延迟控制**：请求带 `keep_alive: "30m"` 让模型驻留；App 启动时发一次空预热请求。目标单次润色 1~2 秒。

## 3. 架构

在 v1 管线中插入一层，新增组件仅一个：

```
录音停止 → AsrService(SenseVoice) → HotwordCorrector → PolishService → TextInjector + HistoryStore
                                                          │
                                          关闭/失败/超时/异常 → 原文直出（降级）
```

- **热词纠正在润色之前**：让 LLM 看到正确的专有名词，避免它"纠正"回错词
- **作用范围**：仅快捷键/面板听写。文件转写 v2 不接润色（长文本延迟与需求不同），留作后续
- **上下文范围**：仅当前这段话，不引入历史转写、不读屏（YAGNI，v2 先把单句做扎实）

### 3.1 PolishService

```swift
final class PolishService: @unchecked Sendable {
    struct Config {          // 全部持久化在 SettingsStore
        var enabled: Bool    // 默认 true
        var baseURL: String  // 默认 "http://localhost:11434/v1"
        var apiKey: String   // 默认空（Ollama 不需要；云端时填）
        var model: String    // 默认 "qwen3.5:4b-nvfp4"
        var style: Style     // .clean（智能清理，默认）| .formal（完全书面化）
    }

    /// 返回润色结果；任何失败返回 nil，调用方使用原文
    func polish(_ text: String) async -> String?
    /// 预热（App 启动时调用，忽略结果）
    func warmUp()
    /// 连通性检测 + 列出可用模型（设置页用，走 Ollama /api/tags；非 Ollama 端点返回仅连通性）
    func probe() async -> ProbeResult
}
```

行为规则：

- 输入 < 5 个字符：跳过润色直接返回原文（不值得等待）
- 非流式请求，`temperature 0.2`，超时 **15 秒**
- 结果校验（防跑偏）：返回文本为空、或长度 > 原文 3 倍 → 视为失败弃用
- 任何失败路径：返回 nil → 调用方用原文 + HUD 提示"润色不可用，已输出原文"，不影响下次

### 3.2 提示词设计

系统提示词模板两档（Swift 常量，配 few-shot 示例）：

- **clean（智能清理，默认）**：删口头禅、应用自我纠正、顺语序补标点、列举转列表；保留说话人的用词和语气；禁止增加原话没有的信息；只输出最终文本
- **formal（完全书面化）**：在 clean 基础上允许重组句式、提升为正式书面表达

few-shot 至少覆盖 4 个金标场景（口头禅/自我纠正/碎片连贯化/列表化），中文为主、含一个中英混说例。输出约束写死在系统提示词里：**只返回处理后的文本本身，不加引号、不加解释**。

## 4. 数据与 UI 变化

### 4.1 数据

`TranscriptRecord` 新增字段：

```swift
var rawText: String?   // 润色前的原始转写；未润色的记录为 nil
```

可选字段，SwiftData 轻量迁移自动兼容 v1 旧数据。

### 4.2 状态机

`AppState.Phase` 新增 `.polishing`：录音 → `transcribing`（识别中…）→ `polishing`（润色中…✨）→ idle。菜单栏图标 polishing 阶段用 `sparkles`。

### 4.3 设置窗口新增「润色」Tab

- 总开关（默认开）
- 风格：智能清理 / 完全书面化
- 服务地址、API Key（默认 Ollama 本地无需填）、模型下拉框（probe 拉取已装模型列表）
- 「测试连接」按钮：显示连通性与模型是否可用；模型缺失时展示 `ollama pull <model>` 指引和一键复制
- HUD 与面板状态区在润色降级时给出原因提示

### 4.4 历史面板

- 历史行显示润色后文本；有 `rawText` 的记录右键菜单增加"复制原始转写"

## 5. 错误处理总表

| 场景 | 行为 |
|---|---|
| 润色开关关闭 | 跳过 PolishService，行为与 v1 完全一致 |
| Ollama 未启动 / 连接拒绝 | 原文直出 + HUD"润色不可用，已输出原文"；设置页测试连接可见原因 |
| 超时 / HTTP 4xx 5xx / 空响应 | 同上，仅本次降级 |
| 返回长度 > 原文 3 倍或为空 | 弃用 LLM 结果，回退原文 |
| 模型未下载 | probe 报"模型缺失"，设置页给 pull 指引 |

## 6. 测试策略

- **单元测试（URLProtocol mock）**：请求体格式（model/messages/temperature/keep_alive）；成功路径解析；超时、HTTP 错误、空响应、超长响应各自回退 nil；短文本跳过；开关关闭跳过
- **集成测试（Ollama 不可达时 XCTSkip）**：temperature 0 跑金标用例，宽松断言——
  - 口头禅例：输出不含"呃""嗯""那个"
  - 自我纠正例：输出含"上午"且不含"下午"
  - 列表例：输出含"1."或"- "
- **提示词回归**：模板改动必须重跑金标集成用例
- 人工验收：真实听写对比开/关润色的输出

## 7. 范围

### v2 交付

1. PolishService（OpenAI 兼容客户端 + 两档提示词 + 降级）
2. 听写管线接入 + `.polishing` 状态 + HUD/图标
3. 设置「润色」Tab（开关/风格/端点/模型/测试连接）
4. 历史保留原始转写 + 右键复制
5. 模型下载指引（README + 设置页 pull 命令展示；**不做自动下载**，用户自行 `ollama pull`）

### 明确不做（YAGNI）

- 文件转写润色、流式逐字上屏、多轮上下文/读屏、自定义提示词编辑器、云端计费管理
