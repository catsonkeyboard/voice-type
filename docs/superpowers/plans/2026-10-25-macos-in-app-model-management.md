# macOS：设置界面一键安装/删除模型（含分离模型）待办

- 日期：2026-10-25
- 状态：**待办**——Windows 侧已实现，macOS 由用户在 MacBook 上实现并测试
- Windows 参考实现（同日完成，提交见 `windows/`）：
  - `windows/src/VoiceType/Services/ModelInstaller.cs` —— 下载/解压/安装/删除的纯逻辑
  - `windows/src/VoiceType/UI/Settings/SettingsWindow.xaml(.cs)` —— 每档模型行的
    「安装/删除」按钮、进度条、确认弹窗、按钮禁用
  - `windows/src/VoiceType/Services/AsrService.cs` —— `LoadedModel` 属性与
    `UnloadAsync()`（删除已加载档位前先卸载）

## 目标

设置 → 识别 里每个识别档位一行：未安装显示「安装」（应用内下载 + 进度），
已安装显示「删除」（确认后删文件）。说话人分离（会议转写）区同样加
「安装/删除」。脚本保留，效果等价。

## 现状（macOS）

装模型只有脚本：`scripts/download_models.sh`（funasr-nano/qwen3/fire-red-ctc）、
`scripts/export_model.sh`（SenseVoice：需要个人 Python venv 的导出 + 顺带补 VAD）、
`scripts/setup_diarization.sh`（pyannote 分段 + 3D-Speaker 声纹）。
设置界面只显示已装/未装状态，没有安装入口。

## 实现要点（Swift 侧）

1. **ModelInstaller（纯逻辑，非 @MainActor）**：对应 Windows 的 ModelInstaller.cs。
   - 下载：URLSession `bytes` 流式写临时文件，按 Content-Length 算进度。
   - 解压：`Process` 调 `/usr/bin/tar -xjf`（系统自带，与 Windows 用 tar.exe 同思路）。
   - 安装布局与脚本一致：子目录档（funasr-nano/qwen3-asr/fire-red-ctc）移动内层
     目录；FireRed 包内 `model.onnx` 改名 `model.int8.onnx`；SenseVoice 的
     `model.int8.onnx`+`tokens.txt` 放 models 根；装识别档位时顺带补
     `silero_vad.onnx`（GitHub-only）。
   - 下载源：ModelScope 优先 `https://modelscope.cn/models/csukuangfj/asr-models/resolve/master/<包名>`，
     失败回退 GitHub `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/<包名>`。
     包名清单照抄 Windows `ModelInstaller.SourceOf`。
   - 分离模型两个文件都是 GitHub-only（segmentation tar.bz2 内取 `model.onnx` 存为
     `segmentation.onnx`；声纹单文件直存 `speaker-embedding.onnx`，注意官方 tag 的
     `recongition` 是历史错拼要保持原样）。
2. **SettingsView（识别 Section）**：每档一行加按钮 + `ProgressView`；
   分离模型区加按钮。安装期间禁用相关控件；删除弹确认（alert）。
3. **AsrService 增加卸载**：现在只有 `reload()`；删除「当前已加载档位」的文件前
   需要先释放 recognizer（对应 Windows 的 `UnloadAsync()`/`LoadedModel`）。
4. **SenseVoice 建议改用预编译包**：Windows 端已经用 sherpa-onnx 预编译
   `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2` 直接下载安装
   （不再走 Python 导出）；macOS 应用内安装同样走下载，个人 venv 导出路径保留给脚本。

## Windows 踩过的坑（别重复）

1. **整个安装必须脱离主线程**：从 UI 调用的 async 代码，await 之后的续体会回到
   主线程（Swift 里 @MainActor 方法内联闭包同理）——下载流、`waitUntilExit` 的
   解压、文件搬移全在主线程跑的话，拖窗口就「未响应」。Windows 最终做法：
   `await Task.Run(install)` 把整段丢线程池；Swift 对应 nonisolated async 函数或
   `Task.detached`，UI 只收进度回调。
2. **进度回调节流**：不能每个读缓冲都上报（1GB ≈ 上万次回调刷爆主线程队列）；
   至少跨 0.5% 报一次，结束时报「下载完成」。
3. **删除前先卸载**：识别模型文件被推理会话占着，直接删失败/留下僵尸内存。
4. **切换档位重载也别卡 UI**（Windows 已修）：释放旧模型 + 加载新模型（GB 级）
   同样要在后台执行，未安装的新档位按正常态不抛。

## 验证

- 装分离模型（35MB，最快）→ 按钮变「删除」、状态已安装、会议转写可用。
- 装 qwen3（约 950MB）→ 进度条走完、状态已安装；安装期间拖动设置窗口不卡。
- 删除当前使用中的档位 → 自动卸载后删除成功；再次听写时按「未安装」提示。
- 删除后再安装回路；VAD 顺带补齐（`models/silero_vad.onnx` 出现）。
- 回归：脚本安装路径不受影响；`./scripts/run_tests.sh` 全过。

## 关联

- `2026-10-25-macos-download-models-vad.md`（download_models.sh 补 VAD 公共步骤）
  仍然独立有效；本功能实现后，应用内安装也会补 VAD，两者不冲突。
