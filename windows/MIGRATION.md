# VoiceType Windows 迁移方案

> 源项目：[voice-type](https://github.com/catsonkeyboard/voice-type)（macOS 14+ / SwiftUI + SwiftData / arm64）
> 目标：仓库 `windows/` 子目录（Windows 10 19041+ / WPF on .NET 10 / x64）
> 本文档描述模块级映射、关键技术决策与差异清单；阶段安排见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)。

## 1. 结论与总体思路

源项目约 2,400 行自有 Swift 代码（另有 2,268 行从官方原样拷贝的 sherpa-onnx Swift 绑定与约 1,100 行测试）。迁移的总体判断：

- **可平移**：识别/VAD/说话人分离（sherpa-onnx 同一份 C API，Windows 官方预编译 DLL）、云端 DashScope WebSocket 协议、LLM 润色 HTTP 协议、热词编辑距离算法、状态机编排逻辑——逐行翻译成 C#。
- **需替换实现**：音频采集（AVAudioEngine → NAudio/WASAPI）、文件解码（AVAudioFile → MediaFoundation）、全局热键（Carbon → `RegisterHotKey`）、文本注入（辅助功能 + CGEvent → `SendInput`）、钥匙串（→ Windows 凭据管理器）、设置/历史存储（UserDefaults/SwiftData → JSON）、登录启动（SMAppService → HKCU Run 键）。
- **需重写**：全部 UI（SwiftUI → WPF XAML）。菜单栏 → 托盘图标 + 面板窗口。
- **直接删除**：2,268 行 vendored Swift 绑定（被约 600 行自研 C# P/Invoke 替代）、辅助功能授权流程（Windows 无此门槛）。

## 2. 模块映射总表

| # | macOS 模块（源文件） | Windows 实现（目标文件） | 关键替代 | 风险 |
|---|---|---|---|---|
| 1 | sherpa-onnx 绑定（`Support/SherpaOnnx.swift`，vendored） | `Interop/SherpaOnnx/SherpaOnnxNative.cs` + 3 个安全包装类 | 自研 P/Invoke（UTF-8 字符串封送，结构体布局按 v1.13.3 C API 逐字段对齐） | 中：结构体字段顺序必须与 c-api.h 完全一致 |
| 2 | 本地识别 `AsrService` | `Services/AsrService.cs` | 同一 C API；串行队列 → `SemaphoreSlim(1,1)` + `Task.Run` | 低 |
| 3 | 说话人分离 `DiarizationService` | `Services/DiarizationService.cs` | 同上 | 低 |
| 4 | 录音 `AudioRecorder`（AVAudioEngine + AVAudioConverter） | `Services/AudioRecorder.cs` | NAudio `WasapiCapture`（共享模式浮点）→ 立体声转单声道 → `WdlResampler` 重采样 16k | 中：NAudio 3.x API 与 2.x 有差异，已用探针工程验证 |
| 5 | 文件解码 `AudioFileDecoder`（AVAudioFile） | `Services/AudioFileDecoder.cs` | `MediaFoundationReader`（wav/mp3/m4a/wma）→ 同上重采样链 | 低 |
| 6 | 会议录音 `MeetingRecorder`（AVAudioFile 写盘） | `Services/MeetingRecorder.cs` | `WaveFileWriter`（16k mono IEEE float WAV） | 低 |
| 7 | 全局热键 `HotkeyManager`（Carbon） | `Services/HotkeyManager.cs` + `Interop/WinHotkey.cs` | `RegisterHotKey` + 消息专用窗口（`HWND_MESSAGE`）`WM_HOTKEY` | 低 |
| 8 | 文本注入 `TextInjector`（AX + CGEvent ⌘V） | `Services/TextInjector.cs` + `Interop/WinInput.cs` | 剪贴板 + `SendInput` 合成 Ctrl+V，600ms 后恢复剪贴板 | 低（比 macOS 简单：无需授权） |
| 9 | 钥匙串 `KeychainStore` | `Interop/CredentialStore.cs` | Windows 凭据管理器 `CredReadW/CredWriteW`（CRED_TYPE_GENERIC） | 低 |
| 10 | 设置 `SettingsStore`（UserDefaults） | `Services/SettingsStore.cs` | `%APPDATA%\VoiceType\settings.json`（System.Text.Json，写时落盘） | 低 |
| 11 | 历史 `HistoryStore`（SwiftData） | `Services/HistoryStore.cs` | `%APPDATA%\VoiceType\history.json`，上限 200 条语义不变 | 低 |
| 12 | 会议稿 `MeetingTranscript`（SwiftData 目录 JSON） | `Models/MeetingTranscript.cs` | 同构 JSON（ISO 日期），`%APPDATA%\VoiceType\meetings\` | 低 |
| 13 | 云端识别协议 `DashScopeAsrProtocol` | `Services/DashScopeAsr.cs` | 纯逻辑，`System.Text.Json`，逐行平移 | 低 |
| 14 | 云端会话 `DashScopeAsrSession`（URLSessionWebSocketTask） | `Services/DashScopeAsrSession.cs` | `ClientWebSocket` + `TaskCompletionSource`（exactly-once 语义用 `Interlocked.Exchange` 保持） | 低 |
| 15 | LLM 润色 `PolishService`/`PolishPrompt` | `Services/PolishService.cs` / `Services/PolishPrompt.cs` | `HttpClient`；keep_alive / reasoning_effort 仅本地端点携带的规则不变；`<think>` 剥离用 `Regex` Singleline | 低 |
| 16 | 热词纠正 `HotwordCorrector`（CFStringTransform 拼音） | `Services/HotwordCorrector.cs` + `IPinyinProvider` | 拼音改用 TinyPinyin.Net（无调号小写，与「MandarinLatin + 去声调」输出等价）；滑窗 + 编辑距离算法逐行平移 | 中：拼音库输出须与测试用例一致（`朗诗德`→`langshide`），已验证 |
| 17 | 听写编排 `DictationController` | `Services/DictationController.cs` | 状态机逐行平移；`Timer` → `DispatcherTimer` | 低 |
| 18 | 会议编排 `MeetingController/Processor` | `Services/Meeting*.cs` | 逐行平移；进度回调经 `Dispatcher` | 低 |
| 19 | 模型路径 `ModelPaths` | `Services/ModelPaths.cs` | 根目录 `%APPDATA%\VoiceType\models`，**子目录布局与 macOS 完全一致**（模型文件通用） | 低 |
| 20 | 调试转储 `DebugAudioDump` | `Services/DebugAudioDump.cs` | `%LOCALAPPDATA%\VoiceType\debug\last-dictation.wav` | 低 |
| 21 | 登录启动（SMAppService） | `Services/LaunchAtLogin.cs` | `HKCU\…\Run` 注册表值 | 低 |
| 22 | UI：`VoiceTypeApp`（MenuBarExtra） | `App.xaml(.cs)` + `UI/Tray` | H.NotifyIcon 托盘图标；图标随阶段切换（空闲/录音） | 中 |
| 23 | UI：`PanelView`（菜单栏面板） | `UI/Panel/PanelWindow.xaml(.cs)` | 常规窗口（宽 360）：状态头、录音按钮、会议区、文件拖放区、历史列表、底栏 | 中（重写） |
| 24 | UI：`SettingsView`（4 Tab） | `UI/Settings/SettingsWindow.xaml(.cs)` | TabControl 四页；「权限」小节替换为麦克风隐私设置入口 | 中（重写） |
| 25 | UI：`RecordingHUD`（NSPanel 置顶悬浮） | `UI/Hud/HudWindow.xaml(.cs)` + `HudController` | 无边框/透明/置顶/不抢焦点/点击穿透（`WS_EX_NOACTIVATE|WS_EX_TRANSPARENT`）窗口，屏幕顶部居中 | 中 |
| 26 | UI：`MeetingResultView` | `UI/Meeting/MeetingResultWindow.xaml(.cs)` | 分段列表 + 说话人改名对话框 + 导出 MD + 生成纪要 | 中（重写） |
| 27 | UI：`KeyComboRecorder` | `UI/Controls/KeyComboRecorder.xaml(.cs)` | 捕获 `PreviewKeyDown`（Alt 组合经 `Key.SystemKey`） | 低 |
| 28 | XCTest × 13 | `src/VoiceType.Tests`（xUnit） | 纯逻辑测试平移；集成测试（模型/网络）标记 Integration 不在 CI 默认运行 | 低 |
| 29 | bash 脚本 × 6 | `scripts/*.ps1` | 见 §5 | 低 |

## 3. 关键技术决策

### 3.1 sherpa-onnx：自研 P/Invoke + 官方 NuGet 原生运行时分发

- 绑定版本与 macOS 端一致锁定 **v1.13.3（onnxruntime 1.24.4）**，模型文件跨平台通用，行为可比。
- 原生 DLL 走 sherpa-onnx **官方 NuGet 分发**：`org.k2fsa.sherpa.onnx.runtime.win-x64` 1.13.3
  （内含 `runtimes/win-x64/native/sherpa-onnx-c-api.dll` + `onnxruntime.dll`，随
  `RuntimeIdentifier=win-x64` 自动复制，杜绝版本错配）；GitHub release 下载脚本
  （`fetch_deps.ps1`）保留为无 NuGet 网络时的手动备选。
- 仅封送实际用到的 API：`OfflineRecognizer`（SenseVoice / FunASR-Nano / Qwen3-ASR 三档配置结构体）、`VoiceActivityDetector`（silero）、`OfflineSpeakerDiarization`。
- **字符串一律按 UTF-8 手工封送**（`Marshal.PtrToStringUTF8` / 自分配 HGlobal UTF-8 字节）。官方 C# 示例程序集用 `CharSet.Ansi`，在含中文的用户名路径（`%APPDATA%` 下）会乱码——这是本工程不直接用其托管 API、自写 P/Invoke 的主因（该 NuGet 包在本工程只取其原生运行时文件）。
- 结构体布局以 v1.13.3 的 `c-api.h` 为准（`fetch_deps.ps1` 会连同 DLL 一起下载该头文件到 `src/VoiceType/Interop/SherpaOnnx/include/`，作为布局校对依据）。`sherpa_onnx_offline_model_config` 含 26 个字段、嵌套 19 个子结构体，字段顺序不允许错位。
- **Windows 导出符号是 UpperCamelCase**（实测 NuGet 包 DLL 的导出表）：`sherpa_onnx_create_offline_recognizer` 在 win-x64 构建里导出为 `SherpaOnnxCreateOfflineRecognizer`（macOS Swift 绑定里的 swift_name 恰好同名，双源可互为校对）。P/Invoke 的 `EntryPoint` 必须用 CamelCase 名。
- 已加 `SherpaOnnxInteropTests`（Integration 分类）冒烟验证：真实 DLL + FunASR-Nano 配置创建识别器并解码模型自带的真实语音（dia_sh.wav 上海话，约 6–9s 含加载），全链路通过。

### 3.2 热键：默认组合键必须换

macOS 默认 `⌥Space`（Option+Space）。Windows 上 Alt+Space 是系统「窗口菜单」快捷键，`RegisterHotKey` 注册不上，**默认改为 `Ctrl+Alt+Space`**（用户可自定义）。修饰键支持 Ctrl/Alt/Shift/Win 四键组合。

### 3.3 文本注入：SendInput，无权限门槛，降级路径保留

- 写剪贴板 → `SendInput` 合成 `Ctrl+V` 按下/抬起 → 600ms 后恢复原剪贴板（与 macOS 逻辑一致）。
- Windows 不需要辅助功能授权：`TextInjector.IsTrusted` 恒为 `true`，整个「去授权」引导流程删除。
- 已知边界（写入文档，不做代码特判）：UIPI 限制导致无法注入到**以管理员运行**的前台窗口；个别全屏独占游戏无效。失败时 `SendInput` 返回 0，自动走「已复制到剪贴板」降级提示。
- 剪贴板操作在 UI 线程执行（WPF `Clipboard` 要求 STA），并对 CLIPBRD_E_CANCELED 做一次重试。

### 3.4 音频链路：WASAPI 共享模式 → 16k mono float

```
WasapiCapture(DataAvailable, 事件驱动，共享模式 float)
  → MediaFoundationResampler(48k/Nch → 16k/mono/float，一步完成降混+重采样)
  → 累积全部样本（听写）/ ~100ms chunk 回调（云端推流 + 会议落盘）
  → RMS*12 电平（HUD）
```
- 无系统级麦克风授权弹窗 API：采集失败（设备被隐私策略关闭/占用）时抛出带「设置 → 隐私 → 麦克风」指引的异常；设置页提供 `ms-settings:privacy-microphone` 直达按钮。
- 会议录音实时写 16k mono IEEE-float WAV（`WaveFileWriter`），与 macOS 端「chunk 落盘、崩溃不丢」语义一致。

### 3.5 存储

| 数据 | macOS | Windows |
|---|---|---|
| 设置 | UserDefaults | `%APPDATA%\VoiceType\settings.json` |
| 历史（≤200 条） | SwiftData SQLite | `%APPDATA%\VoiceType\history.json` |
| 会议稿 | JSON per meeting | `%APPDATA%\VoiceType\meetings\<name>.json`（结构兼容） |
| DashScope/润色 API Key | Keychain | 凭据管理器（Target = `VoiceType/<account>`，CurrentUser 范围） |
| 模型 | `~/Library/Application Support/VoiceType/models` | `%APPDATA%\VoiceType\models`（目录结构一致） |

历史与设置选 JSON 而非 SQLite：上限 200 条、单字段查询，JSON 足够且零依赖；若未来需全文搜索再升级 SQLite。

### 3.6 润色 LLM 差异说明

协议层（OpenAI 兼容 `/chat/completions` + Ollama `/api/tags` 探测）完全不变。差异仅在性能侧：macOS 端推荐 Ollama MLX 后端（Apple 专有），Windows 端 Ollama 走 CPU/CUDA；默认推荐模型改为 `qwen3.5:4b`（非 nvfp4 量化，Windows 官方标签可用），预设仍可在设置页一键切换。

### 3.7 UI 架构

- `AppState` 用 CommunityToolkit.Mvvm 的 `ObservableObject` + `[ObservableProperty]`，供多窗口共享绑定（对应 Swift `@Observable`）。
- 面板/设置/会议窗口以 code-behind 为主（动态段落多、MVVM 收益低），HUD 与托盘为全局单例。
- HUD 顶部居中（macOS 在屏幕下方）；无边框 + `WS_EX_NOACTIVATE | WS_EX_TRANSPARENT` + `Topmost`，不抢焦点、可点击穿透。
- 托盘：H.NotifyIcon（Hardcodet 2.x 维护版）；左键打开面板；右键菜单：面板 / 设置 / 开始-停止听写 / 退出；图标空闲/录音两态。
- 单实例：命名 `Mutex`；重复启动时激活已有面板。

## 4. 行为差异清单（相对 macOS 版）

1. 默认快捷键 `Ctrl+Alt+Space`（Alt+Space 被系统占用）；UI 文案中的 ⌘V 全部改为 Ctrl+V。
2. 无「辅助功能」授权概念；新增「麦克风隐私设置」直达入口。
3. 注入目标为管理员窗口时静默失败 → 自动降级「已复制到剪贴板」提示。
4. HUD 位置：顶部居中（原：屏幕下方）。
5. 会议录音格式 16k mono float WAV（原：同格式 CAF/WAV via AVAudioFile），`MeetingProcessor` 直接读该 WAV。
6. `migrateSecretsToKeychainIfNeeded` 不需要（无历史遗留明文迁移负担），保留空实现位。
7. SenseVoice 安装方式：macOS 端可用 FunASR 检查点本地导出脚本；Windows 端统一改为下载 sherpa-onnx 官方预编译包（`export_sensevoice.ps1`）。

## 5. 脚本迁移

| bash | PowerShell | 说明 |
|---|---|---|
| `fetch_deps.sh` | `scripts/fetch_deps.ps1` | 从 GitHub release v1.13.3 下载 win-x64 shared 包（含 `sherpa-onnx-c-api.dll`、`onnxruntime.dll`、`c-api.h`），展开到 `src/VoiceType/runtimes/win-x64/native/`；资源名不匹配时自动枚举 release assets 兜底 |
| `download_models.sh` | `scripts/download_models.ps1` | funasr-nano / qwen3 / all；ModelScope 优先、GitHub 回退；tar 解包（Win10+ 自带 bsdtar） |
| `setup_diarization.sh` | `scripts/setup_diarization.ps1` | pyannote 分段 + 3D-Speaker 声纹（注意上游 `speaker-recongition-models` 为历史错拼 tag，保持原样） |
| `export_model.sh` | `scripts/export_sensevoice.ps1` | 改为下载官方预编译 SenseVoiceSmall int8（约 230MB） |
| `build.sh` | `scripts/build.ps1` | `dotnet build -c Release`；产物在 `src/VoiceType/bin/Release/win-x64/` |
| `install.sh` | （无） | Windows 免安装，直接运行；发布用 `dotnet publish` |

## 6. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| P/Invoke 结构体与 c-api.h 错位 → 创建识别器崩溃/字段串味 | 高影响/中概率 | 结构体从 v1.13.3 `c-api.h` 逐字段核对（Swift 工厂函数的参数顺序即声明顺序，双源交叉校验）；首次真机运行冒烟：三档模型各转写一条 16k 正弦+静音 |
| onnxruntime.dll 版本错配（sherpa-onnx 上游常见问题） | 中 | 锁定 v1.13.3 配套 1.24.4，DLL 由 fetch_deps.ps1 整包下载、原样部署，不单独升级 |
| NAudio 3.x API 与常见 2.x 示例不一致 | 中 | 已用探针工程验证 `WasapiCapture/WdlResampler/WaveFileWriter/MediaFoundationReader` 均可用；构建期再校 |
| 拼音库输出与 CFStringTransform 细差（多音字/儿化） | 低 | `IPinyinProvider` 抽象隔离；核心用例（`朗诗德→langshide`、`森/盛` 近距纠正）已实测通过 |
| 管理员窗口注入失败、剪贴板被占用 | 低 | 降级提示路径保留；剪贴板重试一次 |
| 长录音 diarization 慢（上游已知，21 分钟音频分钟级） | 低（与 macOS 相同） | 不做额外处理，进度条已有 |

## 7. 目录结构

Windows 版位于仓库 `windows/` 子目录（与 macOS 版同仓共存）：

```
voice-type/                     # 仓库根（macOS 版源码与脚本）
├── VoiceType/                  # Swift/macOS 主程序
├── VoiceTypeTests/
├── scripts/                    # bash 脚本
└── windows/                    # ★ Windows 版（本目录）
    ├── MIGRATION.md            # 本文档
    ├── DEVELOPMENT_PLAN.md     # 开发计划
    ├── README.md
    ├── scripts/                # PowerShell：依赖/模型下载、构建、图标生成
    └── src/
        ├── VoiceType.sln
        ├── VoiceType/          # WPF 主程序
        │   ├── App.xaml(.cs)   # 单实例、托盘、依赖组装
        │   ├── Models/         # TranscriptRecord / SpeakerSegment / MeetingTranscript
        │   ├── Interop/        # SherpaOnnx P/Invoke、SendInput、Hotkey、凭据
        │   ├── Services/       # 业务服务层（与 macOS 同名文件一一对应）
        │   ├── App/            # AppState / AppDependencies
        │   ├── UI/             # Panel / Settings / Hud / Meeting / Controls
        │   └── Assets/         # 托盘图标
        └── VoiceType.Tests/    # xUnit 单元测试
```
