# VoiceType for Windows

**VoiceType** 的 Windows 版（WPF / .NET 10 / x64）：全局热键听写，本地语音识别 +
LLM 润色，文字直接打进光标位置。功能与 macOS 版（本仓库根目录）对齐，
迁移说明见 [MIGRATION.md](MIGRATION.md)，阶段计划见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)。

> 以下命令均以仓库根目录为工作目录（本目录位于仓库 `windows/` 下）。

## 功能

- **热键听写**：按 `Ctrl+Alt+Space`（默认，可自定义）开始，再按结束；识别文本注入当前光标处（写剪贴板 + 合成 Ctrl+V，无需任何系统授权）
- **三档本地模型**（sherpa-onnx v1.13.3，纯离线）：Fun-ASR-Nano-2512（默认）/ Qwen3-ASR-0.6B / SenseVoiceSmall；LLM 档对超 20s 音频自动 VAD 分段
- **智能润色**：OpenAI 兼容端点（默认本地 Ollama）改写口语为书面文本，失败自动回退原文
- **云端识别（可选）**：阿里百炼 Fun-ASR-Realtime 实时流式，HUD 显示中间结果，失败自动回退本地
- **会议转写**：长录音 + 说话人分离（pyannote + 3D-Speaker），说话人改名、导出 Markdown、AI 会议纪要
- 热词拼音纠正、转写历史、音频文件拖放转写、登录自启动

## 快速开始

前置：Windows 10 19041+ / .NET 10 SDK。sherpa-onnx 原生依赖（v1.13.3 win-x64）经
NuGet 包 `org.k2fsa.sherpa.onnx.runtime.win-x64` 自动分发，`dotnet build` 即可。

    powershell -ExecutionPolicy Bypass -File windows\scripts\download_models.ps1 funasr-nano   # 默认模型（约 1GB）
    powershell -ExecutionPolicy Bypass -File windows\scripts\build.ps1

    # 可选：
    powershell -ExecutionPolicy Bypass -File windows\scripts\export_sensevoice.ps1    # SenseVoice（230MB，极速档）
    powershell -ExecutionPolicy Bypass -File windows\scripts\setup_diarization.ps1    # 说话人分离（35MB）
    # 可选（内网无 NuGet 时手动部署原生 DLL）：
    powershell -ExecutionPolicy Bypass -File windows\scripts\fetch_deps.ps1

模型安装到 `%APPDATA%\VoiceType\models\`（与 macOS 端同一布局，模型文件通用）。VAD 模型
`silero_vad.onnx` 由 export_sensevoice.ps1 一并尝试下载；仅影响 >20s 长音频分段与文件转写。

运行：`windows\src\VoiceType\bin\Release\net10.0-windows\win-x64\VoiceType.exe`（托盘常驻，左键托盘打开面板）。

## 测试

    dotnet test windows\src\VoiceType.sln --filter Category!=Integration   # 纯逻辑测试（默认）
    dotnet test windows\src\VoiceType.sln --filter Category=Integration    # P/Invoke 冒烟（需模型 + 原生 DLL）

纯逻辑测试（协议/热词/润色/历史/设置/分离合并）默认运行；依赖模型或网络的集成测试标记为
`Trait("Category", "Integration")`。

## 与 macOS 版的差异

- 默认热键为 `Ctrl+Alt+Space`（Alt+Space 是 Windows 系统快捷键）；提示文案中的 ⌘V 相应为 Ctrl+V
- 文本注入无需辅助功能授权；但无法注入以管理员运行的窗口（UIPI），此场景自动降级为复制到剪贴板
- API Key 存于 Windows 凭据管理器；设置/历史为 `%APPDATA%\VoiceType\` 下 JSON
- 润色默认推荐 `qwen3.5:4b`（Windows 上 Ollama 走 CPU/CUDA，无 MLX）

## 许可

跟随本仓库许可证。
