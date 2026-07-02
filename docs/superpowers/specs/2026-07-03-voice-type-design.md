# VoiceType 设计文档

- 日期：2026-07-03
- 状态：待用户审阅
- 项目根目录：`~/Code/Github/MyCode/voice-type`

## 1. 背景与目标

用户此前有一个 Web 版语音转写项目 voice-flow（Gradio/Python，funasr 库加载 PyTorch 模型）。本项目将其改造为 **macOS 原生菜单栏工具**：SwiftUI 界面、常驻状态栏、单进程内直接调用本地 FunASR 模型推理，无任何 Python/服务端依赖。

成功标准：

- 在任意 App 中按全局快捷键即可听写，识别结果直接输入到光标位置
- 中文（含中英混说）识别准确率与 voice-flow 中 SenseVoiceSmall 一致
- 1 分钟音频转写耗时约 1 秒量级（Apple Silicon CPU）
- 冷启动到可用 ≤ 3 秒（模型常驻内存）

## 2. 技术选型

### 2.1 推理引擎：sherpa-onnx（采用）

对比过的三个方案：

| 方案 | 结论 |
|---|---|
| **sherpa-onnx** | ✅ 采用。底层即 onnxruntime，已封装 fbank 特征提取、CMVN、tokenizer、CTC 解码、VAD、标点；官方支持 SenseVoice/Paraformer；提供 macOS 预编译静态 xcframework 和官方 Swift wrapper（C API 桥接层已写好） |
| onnxruntime C API 自行桥接 | ❌ 需自行重写全部前后处理（特征、BPE 分词、解码），工作量大且易错，无额外收益 |
| Core ML 转换 | ❌ 无官方转换路径，动态 shape/注意力算子转换困难；模型规模下 CPU RTF < 0.05，ANE 加速无必要 |

### 2.2 识别模型：SenseVoiceSmall（int8 ONNX）

- 多语言（中/英/日/粤/韩），自带标点与 ITN（数字归一化），无需额外标点模型
- 非流式，但速度极快，"录完即出"的听写体验延迟可接受（典型一句话 < 300ms）
- VAD 采用 silero-vad（约 2MB），仅用于长音频/文件转写分段；短听写直接整段送入

### 2.3 模型准备：本地导出，不重复下载权重

本地 `~/.cache/modelscope/hub/models/iic/SenseVoiceSmall/model.pt`（893MB）为 PyTorch 格式，sherpa-onnx 无法直接加载。处理方式：

1. **主方案（零权重下载）**：使用 sherpa-onnx 仓库的 `scripts/sense-voice/export-onnx.py`，借 voice-flow 的 `.venv`（已有 torch/funasr，补装 `onnx`、`onnxruntime` 两个小包）对缓存中的 model.pt 做本地导出 + int8 动态量化，产出：
   - `model.int8.onnx`（约 230MB）
   - `tokens.txt`
2. **兜底方案**：导出遇到 funasr/torch 版本兼容问题时，直接下载 sherpa-onnx 官方预转换包 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`（一次性约 230MB）。

模型文件统一放置于 `~/Library/Application Support/VoiceType/models/`，App 启动时校验存在性，缺失时在面板中给出引导。

## 3. 总体架构

单进程 SwiftUI App（`MenuBarExtra`，`LSUIElement = true` 无 Dock 图标）：

```
VoiceType.app
├─ UI 层
│   ├─ MenuBarPanel      状态栏面板：录音按钮、状态、历史列表、文件转写入口
│   ├─ SettingsWindow    设置：快捷键、热词词表、开机自启、模型状态
│   └─ RecordingHUD      录音时的悬浮指示窗（NSPanel，非激活式）
├─ 服务层
│   ├─ HotkeyManager     全局快捷键（Carbon RegisterEventHotKey）
│   ├─ AudioRecorder     AVAudioEngine 采集 → 重采样 16kHz mono Float32
│   ├─ AsrService        sherpa-onnx OfflineRecognizer（SenseVoice int8）+ Silero VAD
│   ├─ TextInjector      结果注入光标：暂存剪贴板 → 写入文本 → CGEvent 合成 ⌘V → 恢复剪贴板
│   ├─ HotwordCorrector  后处理热词纠正（拼音模糊匹配替换）
│   └─ HistoryStore      SwiftData 持久化转写历史
├─ AppState              @Observable 全局状态机（idle / recording / transcribing / error）
└─ SherpaOnnx C API      静态链接 sherpa-onnx.xcframework + 官方 SherpaOnnx.swift wrapper
```

### 3.1 模块职责与接口

| 模块 | 职责 | 关键接口 |
|---|---|---|
| `AsrService` | 模型生命周期 + 推理，串行队列，模型常驻内存 | `func transcribe(samples: [Float]) async throws -> String`；`func transcribeFile(url: URL, onSegment:) async throws -> String` |
| `AudioRecorder` | 麦克风采集、重采样、电平回调（HUD 波形用） | `start() throws` / `stop() -> [Float]` |
| `HotkeyManager` | 注册/更换全局快捷键，回调切换录音 | `register(keyCombo:, handler:)` |
| `TextInjector` | 注入文本到前台 App 光标处 | `func inject(_ text: String) -> InjectResult`（成功 / 降级为剪贴板） |
| `HotwordCorrector` | 词表加载、拼音索引、识别文本纠正 | `func correct(_ text: String) -> String` |
| `HistoryStore` | 历史增删查，上限自动裁剪（默认保留 200 条） | SwiftData `TranscriptRecord` 模型 |

各模块无相互依赖，仅由 `AppState`/协调器编排，均可独立单元测试。

## 4. 核心流程

### 4.1 快捷键听写（主流程）

```
按 ⌥Space（默认，可自定义）
  → HUD 出现，AudioRecorder.start()
再按 ⌥Space（toggle 停止）
  → samples = recorder.stop()
  → text = await asr.transcribe(samples)     // SenseVoice，含标点/ITN
  → text = hotwordCorrector.correct(text)
  → TextInjector.inject(text)                // 成功→光标处出现文字
  → HistoryStore.add(text)
  → HUD 消失
```

- 录音上限 5 分钟（超时自动停止转写），防误触
- 录音 < 0.5s 或 VAD 判空 → 静默取消，不注入
- 转写期间 HUD 显示"识别中…"，完成即消失

### 4.2 文件转写

面板拖入 wav/mp3/m4a（AVFoundation 解码任意格式 → 16kHz mono）→ Silero VAD 分段 → 逐段识别拼接（带段间换行）→ 结果展示在面板，可复制/存入历史。

### 4.3 热词纠正算法

设置中维护词表（每行一个词，如"盛派""朗诗德"）。纠正逻辑：

1. 词表构建拼音索引（词 → 拼音串）
2. 对识别结果以词表中每个词的字数开滑窗，计算窗口文本与热词的拼音编辑距离
3. 距离 ≤ 阈值（按词长比例，默认 ≤ 20%）即替换

说明：SenseVoice 在 sherpa-onnx 中不支持解码期热词偏置（contextual biasing 仅 transducer 模型支持），后处理纠正是工程标准替代。若未来热词要求提高，可增挂 Paraformer 系模型，本设计的 `AsrService` 接口对此保持开放。

## 5. 权限与系统集成

| 能力 | 机制 | 失败处理 |
|---|---|---|
| 麦克风 | Info.plist `NSMicrophoneUsageDescription` + TCC 弹窗 | 面板提示并跳转系统设置 |
| 文本注入 | 辅助功能权限（`AXIsProcessTrusted`），CGEvent 合成 ⌘V | 未授权：首次引导授权；注入失败：文本留在剪贴板 + 通知"已复制，请手动粘贴" |
| 开机自启 | `SMAppService.mainApp` | 设置中开关，注册失败给出提示 |
| 剪贴板保护 | 注入前保存 `NSPasteboard` 内容，粘贴后 200ms 恢复 | — |

App 不启用沙盒（需要辅助功能 API + 读取 Application Support 模型目录），ad-hoc 签名本机使用。

## 6. 工程与构建

- **XcodeGen**（`brew install xcodegen`）：`project.yml` 声明式定义 target/Info.plist/entitlements，生成 `.xcodeproj`；CLI 全自动构建（`xcodebuild`），用户亦可用 Xcode 打开迭代
- **sherpa-onnx**：GitHub Releases 下载官方预编译 `sherpa-onnx.xcframework`（静态库，代码非模型），入库 `Vendor/`；`SherpaOnnx.swift` + `SherpaOnnx-Bridging-Header.h` 取自官方仓库 swift-api-examples
- 目录结构：

```
voice-type/
├─ project.yml
├─ VoiceType/                 # 源码（App、UI、Services、Models）
├─ VoiceTypeTests/
├─ Vendor/sherpa-onnx.xcframework
├─ scripts/
│   ├─ export_model.sh        # 借 voice-flow venv 本地导出 ONNX
│   └─ build.sh               # xcodegen + xcodebuild + 拷贝产物
└─ docs/superpowers/specs/
```

- 最低系统版本 macOS 14（MenuBarExtra + SwiftData + @Observable）

## 7. 错误处理总表

| 场景 | 行为 |
|---|---|
| 模型文件缺失/校验失败 | 面板显著提示 + 指引运行导出脚本（或一键下载兜底包） |
| 模型加载失败 | 状态栏图标置错误态，面板显示错误详情 |
| 录音设备被占用/无输入设备 | HUD 提示错误并结束本次听写 |
| 转写异常 | 通知提示，录音数据不丢（临时 wav 保留在缓存目录，可重试） |
| 前台 App 拦截 ⌘V | 降级：结果进剪贴板 + 系统通知 |

## 8. 测试策略

- **单元测试**（XCTest）：
  - `AsrService`：用 SenseVoiceSmall 模型目录自带的示例 wav 做端到端识别，断言关键文本命中
  - `HotwordCorrector`：拼音模糊替换的命中/误杀边界用例
  - 音频重采样：44.1kHz→16kHz 的长度与幅值校验
- **集成自测**（开发完成时执行）：构建 → 启动 → 面板录音转写 → 文件转写，用脚本+人工结合验证；快捷键注入涉及 TCC 授权，留给用户真机验收
- 明确不做：UI 自动化测试（v1 范围外）

## 9. 功能范围

### v1（本期交付）

1. 全局快捷键听写到光标（toggle 模式，快捷键可自定义）
2. 状态栏面板：手动录音、转写历史（查看/复制/删除）
3. 音频文件转写（拖拽，VAD 分段）
4. 热词词表（后处理纠正）
5. 开机自启开关；录音 HUD

### 明确不在 v1 范围（YAGNI）

- 流式实时上屏、Paraformer 模型切换、说话人分离、字幕文件导出、多快捷键场景（如按住说话模式）、App 内模型下载器
