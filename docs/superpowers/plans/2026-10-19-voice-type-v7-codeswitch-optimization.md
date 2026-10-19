# VoiceType v7 中英混说（Code-Switching）优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 补齐中英混说场景的文本工程短板——热词支持中英混合与别名、润色保护英文术语、内置开发术语表、新增 FireRedASR2-CTC 实验档 + 基准门禁。

**Architecture:** 改动集中在文本后处理层（HotwordCorrector 三态条目重构、PolishPrompt 铁律、DevGlossary 常量合并）与模型档位层（LocalAsrModel/ModelPaths/AsrService 加第四档，vendored 绑定已在位）。设计依据见 `docs/superpowers/specs/2026-10-19-voice-type-v7-codeswitch-optimization-design.md`。

**已核实事实：**
- vendored `VoiceType/Support/SherpaOnnx.swift` 已含 `sherpaOnnxOfflineFireRedAsrCtcModelConfig(model:)` 与 AED 版工厂函数，均已接入 `sherpaOnnxOfflineModelConfig`（tokens 走主 config）；Windows `SherpaOnnxNative.cs` 已有 `fire_red_asr_ctc` 结构体。零运行时升级。
- 模型包：`sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25`（ModelScope csukuangfj/asr-models 与 GitHub sherpa-onnx releases/asr-models 均有；中英混合 + 20 余方言）。tar 包内文件名（model.onnx vs model.int8.onnx）实施时解包确认，必要时在脚本内 mv 重命名。
- 热词构造点仅 2 处：`DictationController.swift:249` 与 `:348`（`HotwordCorrector(hotwords: SettingsStore.hotwords)`）。
- 设置页模型 Picker 遍历 `LocalAsrModel.allCases`（SettingsView.swift:78/138/157），加 case 零 UI 结构改动；热词说明文案在 SettingsView.swift:367（"仅支持中文词"需更新）。
- Windows 侧文件镜像齐全：`HotwordCorrector.cs` / `PolishPrompt.cs` / `SettingsStore.cs` / `ModelPaths.cs` / `AsrService.cs` / `HotwordCorrectorTests.cs` / `SettingsStoreTests.cs` / `download_models.ps1`。
- 新 Swift 文件后需先 `xcodegen` 再跑测试（项目惯例，v4 起如此）。

**测试命令（macOS）：**
```
xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test
```
**测试命令（Windows，Task 7）：**
```
dotnet test windows/src/VoiceType.sln --filter Category!=Integration
```

**文件结构：**
```
（修改）VoiceType/Services/PolishPrompt.swift                    # Task 1
（新建）VoiceTypeTests/PolishPromptTests.swift                   # Task 1
（修改）VoiceType/Services/HotwordCorrector.swift                # Task 2
（修改）VoiceTypeTests/HotwordCorrectorTests.swift               # Task 2
（新建）VoiceType/Services/DevGlossary.swift                     # Task 3
（新建）VoiceTypeTests/DevGlossaryTests.swift                    # Task 3
（修改）VoiceType/Services/DictationController.swift             # Task 3（2 处构造点）
（修改）VoiceType/UI/SettingsView.swift                          # Task 3（文案）
（修改）VoiceType/Services/SettingsStore.swift / AsrService.swift # Task 4
（修改）scripts/download_models.sh                               # Task 4
（修改）VoiceTypeTests/LocalAsrModelSettingsTests.swift          # Task 4
（新建）VoiceTypeTests/AsrBenchmarkTests.swift                   # Task 5
（修改）.gitignore                                               # Task 5
（修改）windows/src/**（6 个文件 + 2 个测试）                     # Task 6
（修改）README.md / README.zh-CN.md                              # Task 7
```

---

### Task 1: 润色提示词英文术语保护（TDD，最小改动先行）

- [x] 新建 `VoiceTypeTests/PolishPromptTests.swift`，先写失败测试：
  - `testCommonRulesContainTermProtection`：断言 `PromptTemplates.clean` 与 `.formal` 均包含 "原样保留" 与 "禁止翻译"；
  - `testPromptMentionsCodeSwitching`：断言两模板含 "中英混合"；
  - `testPromptHasCodeSwitchExamples`：断言 commonRules 区域含 "refactor" 与 "replicas" 示例标记。
- [x] 跑 `xcodegen && xcodebuild ... test -only-testing:VoiceTypeTests/PolishPromptTests` 确认失败
- [x] 改 `PolishPrompt.swift`：
  - `commonRules` 第 5 条后插入新规则："原文中的英文单词、缩写与技术术语（如 API、Kubernetes、cache invalidate、Vue 组件）必须**原样保留**：禁止翻译成中文、禁止改写拼写、禁止变更大小写；中英混说时保留英文嵌入中文的原始语序。"
  - 两处 "以中文为主的语音识别原文" → "中英混合（code-switching）的语音识别原文"
  - 示例区追加：`输入：帮我把这个 function 重构一下尤其是那个 refac…refactor 逻辑 输出：帮我把这个 function 重构一下，尤其是 refactor 逻辑。`；`输入：deployment 的 replicas 应该是三 不对是三个实例 输出：deployment 的 replicas 应该是三个实例。`
- [x] 跑测试确认通过（含既有全部用例）
- [x] Commit `feat(v7): 润色提示词英文术语保护`

### Task 2: 热词系统 v2 —— 三态条目 + 拉丁匹配 + 别名（TDD）

- [x] 扩展 `VoiceTypeTests/HotwordCorrectorTests.swift`，先写失败测试（**既有用例一行不动**）：
  - `testLatinExactMatch`：hotwords `["Kubernetes"]`，"kubernetes 集群" → "Kubernetes 集群"（大小写归位）
  - `testLatinFuzzyMatch`：`["Kubernetes"]`，"kubernets 集群" → "Kubernetes 集群"（编辑距离 1）
  - `testShortLatinOnlyExact`：`["API"]`，"apiary 文档" 不被替换（短词禁模糊）；"api 网关" → "API 网关"
  - `testLatinWithSeparators`：`["CI/CD", "Next.js"]`，"ci/cd 流水线" / "next.js 项目" 归位
  - `testAliasCJK`：`["Kubernetes|库伯内提斯"]`，"部署到库伯内提斯" → "部署到 Kubernetes"
  - `testAliasLatin`：`["PostgreSQL|postgres"]`，"连 postgres 数据库" → "连 PostgreSQL 数据库"
  - `testMixedEntry`：`["Vue 组件"]`，"vu e组件"（或 "vue祖件" 级别扰动）可纠正；纯中文热词旧行为回归由既有用例保证
  - `testLatinNotTouchUnrelated`：`["GraphQL"]`，"graph ql" 不替换（含空格的独立段不匹配单 token 词）——若实现选择支持空格段则改为断言替换，**以实现为准同步修正此用例，二选一在 commit message 注明**
- [x] 跑测试确认新用例失败、旧用例通过
- [x] 重构 `HotwordCorrector.swift`：
  ```swift
  enum Entry {
    case cjk(target: [Character], pinyin: String)        // 纯中文（现逻辑不变）
    case latin(target: String, normalized: String, fuzzy: Bool)  // 含拉丁，fuzzy = normalized.count >= 6
    case alias(target: String, alias: Entry)             // "目标|别名"
  }
  ```
  - `init(hotwords:)`：按 `|` 分割（仅首个 `|`，其余视为目标内字符）→ 左右都非空则 alias；否则整条按是否 allSatisfy(isCJK) 分 cjk / latin；latin 归一化 = lowercased + trim 首尾非字母
  - `correct(_:)`：单次遍历 chars，先尝试拉丁段匹配（游标处取「连续 [字母/数字/-/./÷] 且两端为字母」段），再走既有 CJK 滑窗；alias 委托内部 entry 匹配命中后替换为 target；命中后游标跳过目标长度防重替换
  - 拉丁匹配容差：`fuzzy` 时编辑距离 ≤ ⌈normalized.count×20%⌉，否则仅归一化相等
  - 复用既有 `levenshtein` 与 `pinyin`
- [x] 跑全量测试通过
- [x] Commit `feat(v7): 热词支持中英混合与别名语法 (TDD)`

### Task 3: DevGlossary 内置术语表 + 接入

- [x] 新建 `VoiceTypeTests/DevGlossaryTests.swift`（先失败）：
  - `testMergedDedup`：`merged(withUser: ["kubernetes", "Vue"])` 结果中 "kubernetes" 用户版保留、内置 "Kubernetes" 被覆盖（大小写不敏感去重）
  - `testMergedKeepsAllUser`：用户独有条目全部保留且在前
  - `testGlossaryContainsCommonTerms`：内置表含 "Kubernetes" / "CI/CD" / "GraphQL" / "WebSocket"
- [x] 确认失败后新建 `VoiceType/Services/DevGlossary.swift`：
  ```swift
  enum DevGlossary {
    static let terms: [String] = [ /* ~100 条：框架/工具/缩写，
        Kubernetes, Docker, GraphQL, WebSocket, CI/CD, API, SDK, Xcode,
        SwiftUI, AppKit, macOS, iOS, Linux, TypeScript, JavaScript,
        Python, Rust, Go, Java, JSON, YAML, TOML, HTTP, HTTPS, gRPC,
        Redis, PostgreSQL, MySQL, MongoDB, Nginx, Ollama, tokenizer,
        encoder, decoder, embeddings, cache, deploy, replicas, refactor ... */ ]
    static func merged(withUser user: [String]) -> [String] {
      let userLower = Set(user.map { $0.lowercased() })
      return user + terms.filter { !userLower.contains($0.lowercased()) }
    }
  }
  ```
- [x] `DictationController.swift:249` 与 `:348`：`SettingsStore.hotwords` → `DevGlossary.merged(withUser: SettingsStore.hotwords)`
- [x] `SettingsView.swift:367` 文案改为："每行一个热词（人名、品牌、专业术语；支持中英混合，可用「目标|别名」纠正音译，如 Kubernetes|库伯内提斯）。已内置常见开发术语，无需重复添加。"
- [x] `xcodegen` + 全量测试通过
- [x] Commit `feat(v7): 内置开发术语表并与用户热词合并`

### Task 4: FireRedASR2-CTC 第四档（实验）

- [x] 扩展 `VoiceTypeTests/LocalAsrModelSettingsTests.swift`（先失败）：`fireRedCtc` rawValue = "fireRedCtc"、label 含 "FireRedASR2-CTC"、note 含 "实验"、installCommand = "./scripts/download_models.sh fire-red-ctc"
- [x] `SettingsStore.swift`：`enum LocalAsrModel` 加 `case fireRedCtc`；label "FireRedASR2-CTC（实验）"；note "中英混合 + 20 余种方言，CTC 解码 CPU 快（约 1.7GB，实验）"；installCommand "./scripts/download_models.sh fire-red-ctc"
- [x] `AsrService.swift`：
  - `ModelPaths` 加 `fireRedDir = models/fire-red-ctc/`、`fireRedModel = model.int8.onnx`、`fireRedTokens = tokens.txt`；`isPresent` case 加两文件存在检查
  - `isLLM`：`.fireRedCtc` → false（VAD 分段沿用 SenseVoice 的 20s）
  - `loadedRecognizer()` 加分支：`sherpaOnnxOfflineModelConfig(tokens: ModelPaths.fireRedTokens.path, numThreads: 4, fireRedAsrCtc: sherpaOnnxOfflineFireRedAsrCtcModelConfig(model: ModelPaths.fireRedModel.path))`
- [x] `scripts/download_models.sh`：加 `FIRE_RED_OK` 检查与 `fire-red-ctc|all` case（fetch `sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2` → `fire-red-ctc`；解包后若主文件名非 model.int8.onnx 则 mv 重命名；用法注释同步）；跑 `./scripts/download_models.sh fire-red-ctc` 实测安装成功
- [x] `xcodegen` + 全量测试通过（模型未装时第四档仅不出现在 isPresent，无测试影响）
- [x] Commit `feat(v7): FireRedASR2-CTC 实验档（macOS）`

### Task 5: AsrBenchmarkTests 基准（集成，第四档转正门禁）

- [x] `.gitignore` 加 `benchmark_samples/`
- [x] 新建 `VoiceTypeTests/AsrBenchmarkTests.swift`：
  - 用 `#filePath` 回溯 repo root 定位 `benchmark_samples/*.wav`；目录不存在或无 wav → `XCTSkip`
  - 对 `LocalAsrModel.allCases` 中 `ModelPaths.isPresent` 的档位逐条 `AsrService` 转写（临时切 `SettingsStore.localAsrModel`，teardown 还原），计 RTF
  - `XCTContext`/print 输出「模型 × 样本 × RTF × 输出文本」表；断言各档各样本 RTF < 3.0
- [x] `xcodegen`；无样本目录时跑确认 skip；放入 ≥5 条自录混说 wav 后跑通并留存输出（作为第四档转正依据，报告贴入 PR/commit message）
- [x] Commit `feat(v7): ASR 档位基准测试（RTF 门禁）`

### Task 6: Windows 侧对齐

- [x] `HotwordCorrector.cs`：按 Task 2 同规格重构（Entry 三态 + 拉丁匹配 + 别名），`HotwordCorrectorTests.cs` 同步移植全部新用例；`dotnet test` 通过
- [x] `PolishPrompt.cs`：同步 Task 1 的规则/措辞/示例；相关断言若存在于 PolishServiceTests 则同步
- [x] `SettingsStore.cs`：`LocalAsrModel` 枚举加 `FireRedCtc` + Label/Note/InstallCommand（`.\windows\scripts\download_models.ps1 fire-red-ctc`）；`SettingsStoreTests.cs` 补断言
- [x] `ModelPaths.cs` / `AsrService.cs`：fire-red-ctc 路径族 + IsPresent + OfflineModelKind 分支（`fire_red_asr_ctc` 结构体已在 SherpaOnnxNative.cs）
- [x] `download_models.ps1`：加 fire-red-ctc 目标（与 macOS 同 tar 源）
- [x] `dotnet test windows/src/VoiceType.sln --filter Category!=Integration` 全绿
- [x] Commit `feat(v7): Windows 对齐（热词 v2/术语保护/FireRedCTC）`

### Task 7: README 中英 + 收尾

- [x] `README.zh-CN.md`：热词条目更新（中英混合 + 别名语法示例 + 内置术语表说明）；三档改四档（FireRedASR2-CTC 标"实验"，注明基准门禁未转正）；`download_models.sh` 用法行同步
- [x] `README.md`：英文同步
- [x] macOS 全量测试 + Windows dotnet test 双绿；`./scripts/build.sh` 产出验证
- [x] Commit `feat(v7): 中英混说优化完成` → push
- [x] 用户验收清单：① 设置切第四档录混说句对比 Fun-ASR-Nano；② 热词表加 `Kubernetes|库伯内提斯` 与一个英文术语实测纠错；③ 开润色说 "cache 没有 invalidate" 验证术语不被意译
