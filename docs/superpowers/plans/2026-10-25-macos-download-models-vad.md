# macOS：download_models.sh 补齐 VAD 模型下载（待办）

- 日期：2026-10-25
- 状态：**待办**——Windows 侧已修复（见下），macOS 由用户在 Mac 上修复并测试
- 参考：Windows 同款修复已完成于 `windows/scripts/download_models.ps1`（未提交，与 v7 听写质量同步一起在工作区）

## 问题

`scripts/download_models.sh`（macOS 主安装脚本）**完全没有** `silero_vad.onnx` 的下载逻辑。
整个仓库里唯一会装它的是 `scripts/export_model.sh` 结尾的顺带步骤——但那个脚本本职是
导出 SenseVoice（可选路径），且写死了个人 Python venv
（`$HOME/Code/Github/MyCode/voice-flow/.venv`），换机器跑不了。

后果：只按 README 用 `download_models.sh` 装模型的机器，`~/Library/Application
Support/VoiceType/models/silero_vad.onnx` 永远缺失。影响文件转写
（`AsrService.swift` 的 `vadTranscribe`：解码 → silero VAD 分段 → 逐段识别），
缺失时抛 `AsrError.vadMissing`。快捷键听写不用 VAD，日常无感知。

注意 `ModelPaths.allPresent` 只检查当前识别档位、**不含 VAD**，所以缺 VAD 时
`AsrServiceTests.testTranscribeFileWithVad` 是失败不是跳过——可作为修复验证。

Windows 侧此前有同样的坑（本机 2026-10-25 实测漏装、集成测试失败），已修：
`download_models.ps1` 加了公共步骤，装任何档位都先确保 VAD 在位。

## 修改内容（scripts/download_models.sh，三处）

### 1. 公共步骤：确保 VAD 在位

插入位置：`mkdir -p "$DEST"`（第 12 行）之后、`fetch()` 定义之前：

```bash
# 公共组件：VAD 模型（文件转写分段用），装任何档位都确保存在
# （此前只靠 export_model.sh 顺带下载，装其他档会漏）
if [ ! -f "$DEST/silero_vad.onnx" ]; then
  echo "下载 silero_vad.onnx …"
  # 这个文件只在 GitHub release 有，ModelScope 仓库没有单文件（已验证 404）
  curl -fL --retry 3 --connect-timeout 10 -o "/tmp/silero_vad.onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
  mv "/tmp/silero_vad.onnx" "$DEST/silero_vad.onnx"
else
  echo "silero_vad.onnx 已安装"
fi
```

要点（与 Windows 版行为一致）：

- 先下 `/tmp` 再 `mv`，下载中断不会在 models 目录留半个文件。
- `set -euo pipefail` 下 curl 失败直接报错中止，不静默漏装。
- 只走 GitHub 直链：ModelScope 上没有这个单文件（实测 404），macOS 的
  `export_model.sh` 用的也是同一地址。

### 2. 脚本头注释补一行

在第 7 行 `# SenseVoiceSmall 请用 ./scripts/export_model.sh 导出。` 之后加：

```bash
# 公共组件 silero_vad.onnx 无论装哪档都会自动补齐（文件转写 VAD 分段用）。
```

### 3. 末尾汇总列表加上 silero

第 60 行：

```bash
ls -lh "$DEST" | grep -E 'funasr|qwen3|fire-red|model.int8|tokens'
```

改为：

```bash
ls -lh "$DEST" | grep -E 'funasr|qwen3|fire-red|silero|model.int8|tokens'
```

## 验证

```bash
# 1. 已装场景：应显示 "silero_vad.onnx 已安装"，且不重新下载
./scripts/download_models.sh

# 2. 全新下载场景：删掉后重跑，应从 GitHub 下载（约 630KB），与原文件一致
rm "$HOME/Library/Application Support/VoiceType/models/silero_vad.onnx"
./scripts/download_models.sh
ls -lh "$HOME/Library/Application Support/VoiceType/models/silero_vad.onnx"

# 3. 测试（需识别模型与测试音频在位；缺 VAD 时 testTranscribeFileWithVad 失败，修复后应通过）
./scripts/run_tests.sh AsrServiceTests

# 4. 手工验收：面板拖入一个音频文件转写，正常分段出文字
```

## 可选收尾（不改也能用）

- `README.zh-CN.md`（第 28–29 行附近）与 `README.md`（第 34–35 行附近）：
  现在写的是「export_model.sh 导出 SenseVoiceSmall + 下载 VAD」；可补一句
  `download_models.sh` 也会自动补齐 VAD（Windows 版 README 已同步改过，
  见 `windows/README.md` 第 32–33 行的措辞）。
- `scripts/export_model.sh` 结尾那段 VAD 顺带下载可以保留（无害）或删除
  （职责已移交 download_models.sh），二选一。
