# VoiceType Windows 开发计划

> 配套文档：[MIGRATION.md](MIGRATION.md)（模块映射与技术决策）
> 里程碑按「先跑通主链路、后补齐功能面」组织；每个阶段有明确验收标准。

## 本次交付状态（2026-09-21）

- M0–M5 代码全部完成：解决方案构建 0 错误 0 警告，测试 61 项中 60 通过
- **原生链路已真机验证**：FunASR-Nano 与 SenseVoice 两档模型用真实语音（上海话测试音频）
  解码成功的集成测试均通过——P/Invoke 结构体布局、UTF-8 路径封送、CamelCase 导出符号全部正确
- 唯一未过的测试是 VAD 集成用例：silero_vad.onnx 在本网络环境无法下载
  （GitHub release 域被拦、镜像 401）。手动下载后放入 `%APPDATA%\VoiceType\models\` 即可通过；
  该模型只影响「>20s 长音频 VAD 分段」与「文件转写」，不影响热键听写主链路
- 默认模型 funasr-nano（约 1GB）与 SenseVoice（约 240MB）已安装到 `%APPDATA%\VoiceType\models\`
- 启动冒烟：exe 运行 6 秒不崩溃（托盘/面板/热键注册/设置加载正常）
- sherpa-onnx 原生依赖走官方 NuGet（org.k2fsa.sherpa.onnx.runtime.win-x64 1.13.3，与 macOS 端版本一致）；GitHub 下载脚本保留为内网备选
- 遗留：M6 真机清单——需真实麦克风逐项冒烟（见下）；说话人分离模型（GitHub 35MB）待用户网络下载

## 阶段总览

| 里程碑 | 内容 | 验收标准 | 预估 |
|---|---|---|---|
| M0 工程骨架 | 解决方案/工程/脚本/文档 | `build.ps1` 全绿；空窗口 + 托盘可运行 | 0.5 天 |
| M1 核心链路 | 采集→本地识别→注入 | 热键听写，SenseVoice 文本注入光标处 | 2–3 天 |
| M2 系统集成 | 热键/注入/凭据/登录启动/设置 | 设置页全功能；凭据管理器可见 Key | 1 天 |
| M3 云端与润色 | DashScope WebSocket + LLM 润色 | 云端实时中间结果 + 失败回退；润色与降级 | 1–2 天 |
| M4 会议功能 | 长录音 + 说话人分离 + 结果窗 | 录一场会议出带说话人稿，可导出/纪要 | 1–2 天 |
| M5 打磨 | 历史/热词/文件拖放/HUD/边缘情况 | 与 macOS 版功能对齐；单测全绿 | 1–2 天 |
| M6 真机验证 | 三模型冒烟 + 性能 | 详见 §验收清单 | 0.5 天 |

## M0 工程骨架（已完成于本次交付）

- [x] `src/VoiceType.sln` + `VoiceType`（net10.0-windows, WPF, x64）+ `VoiceType.Tests`（xUnit）
- [x] NuGet：NAudio 3.1（采集/重采样/WAV）、CommunityToolkit.Mvvm 8.4（AppState）、H.NotifyIcon.Wpf 2.4（托盘）、TinyPinyin.Net 1.0.2（热词拼音）
- [x] `scripts/fetch_deps.ps1`：sherpa-onnx v1.13.3 win-x64 shared（DLL + c-api.h）
- [x] `scripts/download_models.ps1` / `setup_diarization.ps1` / `export_sensevoice.ps1` / `build.ps1` / `make_icon.ps1`
- [x] 托盘图标（空闲/录音两态，`make_icon.ps1` 生成）
- 验收：`pwsh scripts/build.ps1` 构建通过；exe 启动出现托盘图标，右键可退出。

## M1 核心链路：采集 → 本地识别 → 注入

服务文件：`SherpaOnnxNative.cs`、`OfflineRecognizer.cs`、`VoiceActivityDetector.cs`、`AudioRecorder.cs`、`AsrService.cs`、`ModelPaths.cs`、`TextInjector.cs`、`DebugAudioDump.cs`、`AppState/AppDependencies`、`HudWindow`。

- [x] P/Invoke：结构体布局对照 `Interop/SherpaOnnx/include/c-api.h` 核对签字
- [x] `AudioRecorder`：WASAPI 采集 → 降混 → 16k 重采样 → 电平/chunk 回调
- [x] `AsrService`：三档模型配置、20s VAD 分段、串行推理、warmUp/reload
- [x] `TextInjector`：剪贴板 + SendInput Ctrl+V + 恢复
- [x] HUD：录音电平条 / 识别中 / 润色中 / 一次性提示
- 验收：`.\scripts\download_models.ps1 funasr-nano` 后，热键（Ctrl+Alt+Space）说完一句话，文字出现在记事本光标处；`debug/last-dictation.wav` 可回放验证采集链路。

## M2 系统集成

- [x] `HotkeyManager`：消息窗口 + RegisterHotKey，设置页 `KeyComboRecorder` 改键即时生效
- [x] `CredentialStore`：CredWrite/CredRead，DashScope 与润色 Key 分账户存储
- [x] `SettingsStore`：settings.json 持久化 + 全部设置项读写
- [x] `LaunchAtLogin`：HKCU Run 键读写；设置页开关
- [x] 设置窗口四页：通用/识别/润色/热词（识别页含模型安装状态、DashScope 连接测试；润色页含服务商预设与连通性探测）
- 验收：改热键后新组合可用；重启后设置保留；凭据管理器出现 `VoiceType/dashscope-api-key`。

## M3 云端识别与 LLM 润色

- [x] `DashScopeAsr` 协议（run-task/finish-task/事件解析/PCM16）+ 单测
- [x] `DashScopeAsrSession`：ClientWebSocket、task-started 5s 超时、finish 15s 超时、partial 实时回调、cancel
- [x] `DictationController` 云端分支：并行建连、失败回退本地（cloudDegraded 提示）
- [x] `PolishService`：OpenAI 兼容请求、`<think>` 剥离、3 倍长度防跑偏、失败回退原文、probe/模型列表
- 验收：云端引擎下 HUD 实时显示中间结果；断网/错 Key 自动回退本地并提示；Ollama 在跑时输出润色文本，历史保留 rawText。

## M4 会议功能

- [x] `MeetingRecorder`：长录音实时落盘 WAV（≤3h 自动停止）
- [x] `DiarizationService`（P/Invoke + 安全包装）+ 相邻段合并
- [x] `MeetingProcessor`：分离 → 合并 → 逐段转写 → JSON 落盘；失败降级整段转写
- [x] `MeetingResultWindow`：分段展示、说话人改名、复制/导出 MD、AI 纪要
- [x] 面板会议区：开始/停止/进度/查看结果；音频文件入口「会议转写…」
- 验收：录制 2 人对话 ≥1 分钟，产出带说话人标签转写；导出 MD 正确；纪要可生成。

## M5 打磨与边缘情况

- [x] `HistoryStore` + 面板历史区（复制/删除/右键复制原文/清空）
- [x] `HotwordCorrector`（含 `IPinyinProvider`）+ 单测对齐 macOS 用例
- [x] 文件拖放转写 + 进度 + 结果复制（wav/mp3/m4a）
- [x] 300s 听写上限、0.5s 最短时长、识别/润色中忽略热键、会议中禁止听写
- [x] 单实例互斥；重复启动激活面板
- [x] 错误文案中文化（麦克风隐私指引、模型缺失安装命令 `.\scripts\…`）
- 验收：单元测试全绿（协议/热词/润色/历史/设置/分离合并）；功能面与 macOS 版逐项对齐。

## M6 真机验证清单

- [ ] 三档模型各冒烟：SenseVoice（<1s）、FunASR-Nano、Qwen3-ASR（1–3s 量级）
- [ ] >20s 长句听写：LLM 档自动 VAD 分段、段间换行
- [ ] 文件转写 + 会议转写（含降级路径：删除 diarization 模型重试）
- [ ] 热词纠正、云端回退、润色回退三提示路径
- [ ] 注入目标矩阵：记事本 / Word / 浏览器输入框 / VS Code（管理员窗口预期降级，确认提示）
- [ ] 冷启动时间（模型 warmUp 后首听写延迟）记录到 README 性能小节

## 测试策略

- 单测（xUnit，平移自 XCTest 纯逻辑部分）：`DashScopeAsrProtocolTests`、`HotwordCorrectorTests`（IPinyinProvider 注入假实现 + TinyPinyin 真实现两组）、`PolishServiceTests`（假 HttpMessageHandler）、`DiarizationLogicTests`（合并逻辑）、`HistoryStoreTests`、`SettingsStoreTests`（临时目录）、`LocalAsrModelSettingsTests`、`Pcm16/Assembler` 用例。
- 集成测试不进默认队列：模型/网络依赖项以 `[Trait("Category", "Integration")]` 标记。
- P/Invoke 冒烟独立脚本化（`scripts/smoke_asr.ps1`，M6 阶段补充）。

## 明确不做（本期范围外）

- MSIX 打包/代码签名/自动更新（直接以 win-x64 目录分发，后续按需补）
- GPU 推理（DirectML/CUDA provider 参数已留位，默认 cpu）
- 多语言 UI、深色主题跟随（WPF 默认样式即可）
- 全文搜索/更多导出格式
