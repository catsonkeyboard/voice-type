# VoiceType v7 设计文档：中英混说（Code-Switching）优化

- 日期：2026-10-19
- 状态：待用户审阅
- 前置：v5 本地三档模型、v6 桌宠桥接已交付，见同目录既有 spec
- 背景：22 款竞品调研（重点：Azex Speech / VoxFlow / LocalScribe / Ottex / OpenTypeless）

## 1. 背景与结论

竞品分析结论（详见 2026-10-19 会话）：voice-type 的模型层并不落后——默认档
Fun-ASR-Nano-2512 本身主打 code-switching。**真正的差距在文本工程**：

| 竞品 | 借鉴价值 | 决定 |
|---|---|---|
| Azex Speech | 4 层纠错架构（纯文本工程，与模型无关） | **采纳**（v7 核心） |
| VoxFlow | 双路并行复核 | 思路记档，YAGNI 暂不做 |
| LocalScribe | SenseVoice 同款，是我们的子集 | 无可借鉴 |
| Ottex / OpenTypeless | 中文强靠云端链路 | 不跟（与"本地优先"定位冲突） |
| FireRedASR v2 | sherpa-onnx 新增 CTC 模型，CPU 快、中英混合+方言 | **实验档采纳**，实测门禁 |

## 2. 现状差距（代码级）

1. **`HotwordCorrector` 拒收含英文的热词**：`init` 中 `allSatisfy(Self.isCJK)`
   把 "Kubernetes"、"GraphQL"、"Vue 组件" 这类条目静默过滤。主打中英混说的
   听写工具，热词系统认不得英文——这是最直接的短板。
2. **`PolishPrompt` 无英文术语保护规则**：提示词写死"以中文为主"，未要求
   保留英文术语原文。LLM 润色可能把 "cache 没有 invalidate" 意译成
   "缓存未失效"，技术转写场景不可接受。
3. **无内置术语表**：常见开发术语（API/Kubernetes/CI 等）的纠错完全依赖
   用户手工录入热词，冷启动为零。
4. **模型档位缺 FireRedASR2-CTC 候选**：vendored SherpaOnnx.swift 已含
   `sherpaOnnxOfflineFireRedAsrCtcModelConfig(model:)` 绑定（连同 AED 版，
   均已接入 `sherpaOnnxOfflineModelConfig`，Windows C# interop 同样在位），
   加档只差路径/配置/脚本，零运行时升级。

## 3. 架构

### 3.1 热词系统 v2（`HotwordCorrector` 重构）

热词条目语法扩展为两种形式：

```
Kubernetes              ← 纯拉丁/混合条目：模糊匹配识别结果中的英文片段
Kubernetes|库伯内提斯    ← 别名条目：识别结果出现拼音近似「库伯内提斯」时替换为 Kubernetes
张三丰                  ← 纯中文条目：行为与现状完全一致（拼音滑窗）
```

匹配策略按条目类型分流（互不干扰）：

| 条目类型 | 匹配对象 | 算法 |
|---|---|---|
| 纯 CJK（现状） | 文本 CJK 窗口 | 拼音编辑距离 ≤ ⌈len×20%⌉（不变） |
| 含拉丁（自目标） | 文本拉丁连续段 | 归一化（小写、去首尾标点）后编辑距离 ≤ ⌈len×20%⌉（len≥6，短词仅精确匹配防误替换） |
| 别名（`目标|别名`） | 别名按上两行规则匹配 | 命中后整段替换为目标 |

明确不做（YAGNI / 误替换风险）：跨语言自动音译桥接（自动把英文热词生成中文
音译候选）。用户需要时用别名语法显式声明。

纯拉丁条目匹配窗口取「连续拉丁+内部连字符/点/空格」段（覆盖 "CI/CD"、
"Next.js"）。替换后保留目标原拼写与大小写。

### 3.2 润色提示词：英文术语保护（`PolishPrompt`）

- `commonRules` 新增铁律：**原文中的英文单词、缩写与技术术语必须原样保留：
  禁止翻译成中文、禁止改写拼写、禁止变更大小写；中英混说时保留英文嵌入中文
  的原始语序**。
- "以中文为主的语音识别原文" → "中英混合（code-switching）的语音识别原文"。
- 新增 2 个 code-switch few-shot 示例（function refactor / deployment replicas）。
- 既有 5 条规则与其余示例不动。

### 3.3 内置开发术语表（`DevGlossary`）

- 编译进二进制的 Swift 常量（非 bundle 资源，避免 xcodegen 资源步骤），
  约 80–120 条常见开发术语（框架名/缩写/工具名，如 Kubernetes、GraphQL、
  CI/CD、WebSocket、macOS、SwiftUI、Tokenizer……）。
- `DictationController` 构造 `HotwordCorrector` 时：用户热词 + 内置术语表
  合并去重（用户条目优先，允许同名覆盖）。
- 设置页热词区加一行说明：「已内置常见开发术语表，个人词条在下方追加即可」。
- 纯拉丁长术语走 3.1 的拉丁模糊匹配，即自动获得纠错能力。

### 3.4 FireRedASR2-CTC 第四档（实验）

- `LocalAsrModel` 新增 `.fireRedCtc`，label「FireRedASR2-CTC（实验）」，
  note「中英混合 + 20 余种方言，CTC 解码 CPU 快」。不设为默认。
- 模型：`sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25`
  （v2 仓库仅转出 CTC 分支；AED v1 官方承认 CPU 慢，不收）。安装布局
  `models/fire-red-ctc/{model.int8.onnx, tokens.txt}`。
- `AsrService`：`fireRedAsrCtc: sherpaOnnxOfflineFireRedAsrCtcModelConfig(model:)`
  + `tokens` 走主 config；`isLLM = false`（沿用 SenseVoice 的 20s VAD 分段）。
- `download_models.sh` 增加 `fire-red-ctc` 目标（URL 实施时以 sherpa-onnx
  releases 页为准校验）。
- **实测门禁**：基准测试（3.5）通过（RTF 与混说准确率不劣于 Fun-ASR-Nano
  或有明显互补优势）后，才在 README 推荐；未达标保持"实验"标注，不转正。

### 3.5 基准测试（`AsrBenchmarkTests`，集成）

- 输入：本地 `benchmark_samples/` 目录（gitignore）下用户自录的中英混说
  wav 若干（≥5 条，含术语密集句）。目录缺失 → XCTSkip。
- 对**已安装的全部档位**逐条转写，输出表格：模型 × 平均 RTF × 输出文本。
  断言各档 RTF < 3.0（听写可用性底线）。
- 用途：第四档转正门禁 + 未来换默认档的依据。不做自动准确率判定
  （无 ground-truth 标注，人工比对输出表）。

## 4. 既有组件改动总表

| 组件 | 改动 |
|---|---|
| `HotwordCorrector` | 条目解析三态 + 拉丁模糊匹配 + 别名替换；纯中文路径行为不变 |
| `PolishPrompt` | 新增术语保护铁律 + 2 示例 + 措辞改"中英混合" |
| `DevGlossary`（新） | 内置术语常量 + 合并去重纯函数 |
| `SettingsStore` / `LocalAsrModel` | `.fireRedCtc` case + label/note/installCommand |
| `ModelPaths` / `AsrService` | fire-red-ctc 路径族 + `isPresent` + modelConfig 分支 |
| `DictationController` | 构造 corrector 时合并内置术语表 |
| `SettingsView` | 模型 Picker 增第四档；热词区加内置表说明 |
| `scripts/download_models.sh` | `fire-red-ctc` 目标 |
| Windows | `download_models.ps1` 同目标 + 模型枚举/设置对齐（interop 已有结构体，最小改动） |
| README 中英 | 热词语法说明（别名竖线）+ 第四档（实验标注）+ 术语表提及 |

## 5. 测试策略

- **单元（新增/扩展）**：
  - `HotwordCorrectorTests`：纯拉丁精确/模糊（kubernets→Kubernetes）、
    短词不模糊（API 不误伤 apiary 类风险场景）、大小写保留、别名拼音替换、
    `CI/CD`/`Next.js` 含分隔符段、混合条目（Vue 组件）、纯中文行为回归。
  - `DevGlossaryTests`：合并去重、用户覆盖优先。
  - `PolishPromptTests`：模板含术语保护规则与 code-switch 示例断言。
  - `LocalAsrModelSettingsTests`：第四档 rawValue/label/installCommand。
- **集成**：`AsrBenchmarkTests`（3.5，samples 缺失跳过）。
- **回归**：现有 14 个测试文件全绿；重点 `HotwordCorrectorTests` 旧用例
  逐条不动、必须全过（纯中文零回归）。
- **人工验收**：录三句混说（含 2 个术语表词 + 1 个自定义英文热词），
  开润色验证术语原样保留。

## 6. 范围

### v7 交付

1. 热词系统 v2（拉丁模糊 + 别名语法，纯中文路径零回归）
2. 润色提示词术语保护
3. 内置开发术语表 + 合并
4. FireRedASR2-CTC 实验档（macOS + Windows 下载脚本）
5. `AsrBenchmarkTests` 基准 + 第四档实测报告（转正门禁）
6. README 中英更新

### 明确不做（YAGNI）

- VoxFlow 式双路并行复核（内存×2，远期再议）
- Azex 式误识别回滚/缓冲注入 UX（属 TextInjector 交互层，v8 候选）
- 跨语言自动音译桥接（误替换风险，别名语法已覆盖显式需求）
- FireRedASR AED v1（CPU 慢）、云端术语纠错、热词词表云端同步
