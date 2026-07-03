# VoiceType Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 菜单栏语音转写工具：全局快捷键听写到光标、面板录音/历史/文件转写、热词纠正，单进程内嵌 sherpa-onnx + SenseVoice int8。

**Architecture:** SwiftUI `MenuBarExtra` App（LSUIElement），服务层（AsrService / AudioRecorder / HotkeyManager / TextInjector / HotwordCorrector / HistoryStore）由 `DictationController` 编排，`AppState`（@Observable）驱动 UI。推理链接 sherpa-onnx 官方预编译 dylib（含 onnxruntime），模型由本地 PyTorch 权重导出为 ONNX int8。

**Tech Stack:** Swift 5.9 / SwiftUI / SwiftData / AVFoundation / Carbon HotKey / CGEvent / XcodeGen / sherpa-onnx v1.13.3

**已核实的事实（执行时不要再猜）：**
- 依赖包：`https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-onnxruntime-1.24.4-osx-arm64-shared.tar.bz2`（28MB），内含 `lib/libsherpa-onnx-c-api.dylib`（install name `@rpath/libsherpa-onnx-c-api.dylib`，依赖 `@rpath/libonnxruntime.1.24.4.dylib`）、`lib/libonnxruntime.1.24.4.dylib`、`include/sherpa-onnx/c-api/c-api.h`。均为 arm64。注意：不要用 macos-xcframework-static 包，它未捆绑 onnxruntime。
- Swift 封装：`https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.3/swift-api-examples/SherpaOnnx.swift` 与 `SherpaOnnx-Bridging-Header.h`（scratchpad 已有缓存副本）。关键 API：`sherpaOnnxOfflineSenseVoiceModelConfig(model:language:useInverseTextNormalization:)`、`sherpaOnnxOfflineModelConfig(tokens:numThreads:senseVoice:)`、`sherpaOnnxFeatureConfig()`、`sherpaOnnxOfflineRecognizerConfig(featConfig:modelConfig:)`、`SherpaOnnxOfflineRecognizer(config:&cfg)`、`.decode(samples:sampleRate:) -> SherpaOnnxOfflineRecongitionResult`（注意类名拼写就是 Recongition）、`sherpaOnnxSileroVadModelConfig(model:threshold:minSilenceDuration:minSpeechDuration:windowSize:maxSpeechDuration:)`、`sherpaOnnxVadModelConfig(sileroVad:)`、`SherpaOnnxVoiceActivityDetectorWrapper(config:buffer_size_in_seconds:)`（方法 acceptWaveform/isEmpty/front/pop/flush；segment 有 `.samples`）。
- 模型导出：`scripts/sense-voice/export-onnx.py`（v1.13.3 tag）`from model import SenseVoiceSmall` —— `model.py` 来自 `https://github.com/FunAudioLLM/SenseVoice` 仓库（浅克隆后加入 PYTHONPATH）。`SenseVoiceSmall.from_pretrained(model="iic/SenseVoiceSmall")` 走 funasr 下载逻辑，会命中本地 `~/.cache/modelscope/hub/models/iic/SenseVoiceSmall`（已有 model.pt，无需重新下载权重）。脚本在 CWD 产出 `tokens.txt`、`model.onnx`、`model.int8.onnx`。python 环境用 voice-flow 的 venv：`~/Code/Github/MyCode/voice-flow/.venv`（已有 torch/funasr，缺 onnx/onnxruntime 需 pip 装）。
- 兜底模型包（导出失败时用）：`https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2`
- silero VAD 模型：`https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`（约 2MB）
- 测试音频：`~/.cache/modelscope/hub/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch/asr_example_hotword.wav`（248K，中文）
- 模型安装目录：`~/Library/Application Support/VoiceType/models/`（model.int8.onnx / tokens.txt / silero_vad.onnx）

**文件结构：**

```
voice-type/
├─ project.yml                      # XcodeGen 工程定义
├─ scripts/
│   ├─ fetch_deps.sh                # 拉 sherpa-onnx dylib + Swift 封装
│   ├─ export_model.sh              # 本地导出 SenseVoice ONNX int8 + VAD
│   ├─ verify_model.py              # python 侧验证导出的模型可识别
│   └─ build.sh                     # xcodegen + xcodebuild + 产出 dist/
├─ Vendor/sherpa-onnx/              # (gitignore) lib/*.dylib + include/
├─ VoiceType/
│   ├─ App/VoiceTypeApp.swift       # @main MenuBarExtra + Settings scene
│   ├─ App/AppDependencies.swift    # 组装所有服务（@Observable，入 environment）
│   ├─ App/AppState.swift           # 全局状态机 phase/micLevel/hudMessage
│   ├─ Services/AsrService.swift    # 模型加载 + 转写 + VAD 文件转写
│   ├─ Services/AudioFileDecoder.swift  # 任意音频文件 → 16k mono [Float]
│   ├─ Services/AudioRecorder.swift # AVAudioEngine 采集 → 16k mono [Float]
│   ├─ Services/DictationController.swift  # 听写编排（录→转→纠→注入→历史）
│   ├─ Services/HotkeyManager.swift # Carbon 全局快捷键
│   ├─ Services/TextInjector.swift  # 剪贴板 + ⌘V 注入
│   ├─ Services/HotwordCorrector.swift  # 拼音模糊热词纠正
│   ├─ Services/HistoryStore.swift  # SwiftData TranscriptRecord
│   ├─ Services/SettingsStore.swift # UserDefaults 封装
│   ├─ UI/PanelView.swift           # 菜单栏面板（录音/历史/文件转写）
│   ├─ UI/RecordingHUD.swift        # 悬浮 HUD（NSPanel + SwiftUI）
│   ├─ UI/SettingsView.swift        # 设置窗口
│   ├─ UI/KeyComboRecorder.swift    # 快捷键录制控件
│   └─ Support/                     # (vendored) SherpaOnnx.swift + 桥接头
└─ VoiceTypeTests/
    ├─ HotwordCorrectorTests.swift
    ├─ AudioFileDecoderTests.swift
    ├─ AsrServiceTests.swift        # 端到端，模型缺失时 XCTSkip
    └─ HistoryStoreTests.swift
```

**通用命令：**
- 生成工程：`xcodegen`（在项目根目录）
- 构建：`xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -configuration Debug -destination 'platform=macOS' build`
- 测试：`xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test`

与 spec 的两处已确认偏差（实现更简单，行为等价）：① 注入失败提示用 HUD 短消息而非系统通知（免通知权限）；② sherpa-onnx 依赖用官方 dylib 而非静态 xcframework（后者不含 onnxruntime）。

---

### Task 1: 依赖脚本 + XcodeGen 工程脚手架

**Files:**
- Create: `scripts/fetch_deps.sh`
- Create: `project.yml`
- Create: `VoiceType/App/VoiceTypeApp.swift`（临时最小版，Task 9 替换）
- Create: `.gitignore`

- [ ] **Step 1: 安装 xcodegen（如缺失）**

Run: `which xcodegen || brew install xcodegen`

- [ ] **Step 2: 写 `.gitignore`**

```gitignore
.DS_Store
build/
dist/
DerivedData/
Vendor/
*.xcodeproj
```

- [ ] **Step 3: 写 `scripts/fetch_deps.sh`**

```bash
#!/bin/bash
# 下载 sherpa-onnx 预编译 dylib（含 onnxruntime）与官方 Swift 封装
set -euo pipefail
cd "$(dirname "$0")/.."
VER=v1.13.3
PKG="sherpa-onnx-$VER-onnxruntime-1.24.4-osx-arm64-shared"

if [ ! -f "Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib" ]; then
  mkdir -p Vendor
  curl -sL -o "/tmp/$PKG.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/$VER/$PKG.tar.bz2"
  tar xjf "/tmp/$PKG.tar.bz2" -C Vendor
  rm -rf Vendor/sherpa-onnx
  mv "Vendor/$PKG" Vendor/sherpa-onnx
  rm -f "/tmp/$PKG.tar.bz2"
fi

mkdir -p VoiceType/Support
for f in SherpaOnnx.swift SherpaOnnx-Bridging-Header.h; do
  if [ ! -f "VoiceType/Support/$f" ]; then
    curl -sL -o "VoiceType/Support/$f" \
      "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VER/swift-api-examples/$f"
  fi
done
echo "deps ok:"
ls Vendor/sherpa-onnx/lib
```

执行时注意：scratchpad 已有下载好的包（`ort.tar.bz2` 解压产物）和 `SherpaOnnx.swift`，可直接拷贝进 Vendor/ 与 VoiceType/Support/ 省去重复下载，脚本的存在性判断会跳过已就位文件。

- [ ] **Step 4: 运行 `chmod +x scripts/*.sh && ./scripts/fetch_deps.sh`**

Expected: 打印 `deps ok:` 及 4 个 dylib 文件名；`VoiceType/Support/` 出现两个文件。

- [ ] **Step 5: 写 `project.yml`**

```yaml
name: VoiceType
options:
  bundleIdPrefix: com.catsonkeyboard
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.9"
    ARCHS: arm64
    CODE_SIGN_IDENTITY: "-"
    SWIFT_OBJC_BRIDGING_HEADER: VoiceType/Support/SherpaOnnx-Bridging-Header.h
    HEADER_SEARCH_PATHS: "$(SRCROOT)/Vendor/sherpa-onnx/include"
    LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
targets:
  VoiceType:
    type: application
    platform: macOS
    sources:
      - VoiceType
    dependencies:
      - framework: Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib
        embed: true
        codeSign: true
      - framework: Vendor/sherpa-onnx/lib/libonnxruntime.1.24.4.dylib
        embed: true
        codeSign: true
    info:
      path: VoiceType/Info.plist
      properties:
        CFBundleDisplayName: VoiceType
        LSUIElement: true
        NSMicrophoneUsageDescription: VoiceType 需要访问麦克风进行语音转写。
schemes:
  VoiceType:
    build:
      targets:
        VoiceType: all
        VoiceTypeTests: [test]
    test:
      targets:
        - VoiceTypeTests
```

注意：`VoiceTypeTests` target 在 Task 3 才加入 project.yml（见 Task 3 Step 1）；本任务先只留 scheme 的 build/test 里去掉 VoiceTypeTests（否则 xcodegen 报未知 target）。即本步的 scheme 写成：

```yaml
schemes:
  VoiceType:
    build:
      targets:
        VoiceType: all
```

- [ ] **Step 6: 写临时最小 App `VoiceType/App/VoiceTypeApp.swift`**

```swift
import SwiftUI

@main
struct VoiceTypeApp: App {
    var body: some Scene {
        MenuBarExtra("VoiceType", systemImage: "mic") {
            Text("VoiceType 开发中").padding()
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .padding(.bottom, 8)
        }
    }
}
```

- [ ] **Step 7: 生成工程并构建**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add .gitignore project.yml scripts/fetch_deps.sh VoiceType
git commit -m "chore: 工程脚手架 + sherpa-onnx 依赖脚本"
```

---

### Task 2: 模型导出与验证

**Files:**
- Create: `scripts/export_model.sh`
- Create: `scripts/verify_model.py`

- [ ] **Step 1: 写 `scripts/export_model.sh`**

```bash
#!/bin/bash
# 将本地 modelscope 缓存中的 SenseVoiceSmall (PyTorch) 导出为 ONNX int8，
# 并安装到 ~/Library/Application Support/VoiceType/models/
# 权重零下载：from_pretrained 命中 ~/.cache/modelscope 缓存。
set -euo pipefail
VENV="$HOME/Code/Github/MyCode/voice-flow/.venv"
VER=v1.13.3
DEST="$HOME/Library/Application Support/VoiceType/models"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST"

if [ ! -f "$DEST/model.int8.onnx" ] || [ ! -f "$DEST/tokens.txt" ]; then
  "$VENV/bin/pip" install -q onnx onnxruntime
  git clone -q --depth 1 https://github.com/FunAudioLLM/SenseVoice "$WORK/SenseVoice"
  cd "$WORK"
  curl -sLO "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VER/scripts/sense-voice/export-onnx.py"
  PYTHONPATH="$WORK/SenseVoice" "$VENV/bin/python" export-onnx.py
  cp model.int8.onnx tokens.txt "$DEST/"
fi

if [ ! -f "$DEST/silero_vad.onnx" ]; then
  curl -sL -o "$DEST/silero_vad.onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
fi
ls -lh "$DEST"
```

- [ ] **Step 2: 运行导出**

Run: `chmod +x scripts/export_model.sh && ./scripts/export_model.sh`
Expected: 目标目录列出 `model.int8.onnx`（约 230MB）、`tokens.txt`、`silero_vad.onnx`。导出耗时数分钟（torch.onnx.export + 量化）。

失败兜底（仅当导出报错且无法快速修复，如 torch 版本不兼容）：

```bash
DEST="$HOME/Library/Application Support/VoiceType/models"
curl -sL -o /tmp/sv.tar.bz2 "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
tar xjf /tmp/sv.tar.bz2 -C /tmp
cp /tmp/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx \
   /tmp/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt "$DEST/"
```

- [ ] **Step 3: 写 `scripts/verify_model.py`**

```python
#!/usr/bin/env python3
"""用 sherpa-onnx python 包验证导出模型可正常识别（与 Swift 侧同一运行时）。"""
import sys
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf

MODELS = Path.home() / "Library/Application Support/VoiceType/models"
WAV = (
    Path.home()
    / ".cache/modelscope/hub/models/iic"
    / "speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
    / "asr_example_hotword.wav"
)

recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model=str(MODELS / "model.int8.onnx"),
    tokens=str(MODELS / "tokens.txt"),
    use_itn=True,
)
samples, rate = sf.read(str(WAV), dtype="float32")
if samples.ndim > 1:
    samples = samples.mean(axis=1)
stream = recognizer.create_stream()
stream.accept_waveform(rate, samples)
recognizer.decode_stream(stream)
text = stream.result.text
print("识别结果:", text)
cjk = sum(1 for c in text if "一" <= c <= "鿿")
assert cjk >= 4, f"中文字符过少: {text!r}"
print("OK")
```

- [ ] **Step 4: 运行验证**

Run:
```bash
VENV="$HOME/Code/Github/MyCode/voice-flow/.venv"
"$VENV/bin/pip" install -q sherpa-onnx soundfile
"$VENV/bin/python" scripts/verify_model.py
```
Expected: 打印中文识别结果 + `OK`。人工核对结果是否通顺带标点。

- [ ] **Step 5: Commit**

```bash
git add scripts/export_model.sh scripts/verify_model.py
git commit -m "feat: SenseVoice ONNX 本地导出与验证脚本"
```

---

### Task 3: AudioFileDecoder（TDD）

**Files:**
- Create: `VoiceType/Services/AudioFileDecoder.swift`
- Create: `VoiceTypeTests/AudioFileDecoderTests.swift`
- Modify: `project.yml`（加入测试 target 与 scheme test）

- [ ] **Step 1: project.yml 加测试 target**

在 `targets:` 下追加：

```yaml
  VoiceTypeTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - VoiceTypeTests
    dependencies:
      - target: VoiceType
```

并把 scheme 恢复为 Task 1 Step 5 中的完整形式（build 含 `VoiceTypeTests: [test]`，test 含 `VoiceTypeTests`）。

- [ ] **Step 2: 写失败测试 `VoiceTypeTests/AudioFileDecoderTests.swift`**

```swift
import AVFoundation
import XCTest

@testable import VoiceType

final class AudioFileDecoderTests: XCTestCase {
    /// 生成 44.1kHz 立体声 1 秒正弦波 wav，解码后应得到约 16000 个单声道采样
    func testDecodeResamplesTo16kMono() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames: AVAudioFrameCount = 44100
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = sinf(2 * .pi * 440 * Float(i) / 44100) * 0.5
            }
        }
        try file.write(from: buf)

        let samples = try AudioFileDecoder.decode16kMono(url: url)

        XCTAssertGreaterThan(samples.count, 15200)
        XCTAssertLessThan(samples.count, 16800)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testDecodeMissingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/file.wav")
        XCTAssertThrowsError(try AudioFileDecoder.decode16kMono(url: url))
    }
}
```

- [ ] **Step 3: 运行测试确认失败（编译错误：AudioFileDecoder 未定义）**

Run: `xcodegen && xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL（cannot find 'AudioFileDecoder'）

- [ ] **Step 4: 实现 `VoiceType/Services/AudioFileDecoder.swift`**

```swift
import AVFoundation

enum AudioDecodeError: LocalizedError {
    case unsupportedFormat
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "不支持的音频格式"
        case .conversionFailed(let msg): return "音频转换失败：\(msg)"
        }
    }
}

enum AudioFileDecoder {
    /// 解码任意 AVFoundation 支持的音频文件（wav/mp3/m4a...）为 16kHz 单声道 Float32
    static func decode16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard
            let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { throw AudioDecodeError.unsupportedFormat }

        var result: [Float] = []
        var reachedEnd = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if reachedEnd {
                status.pointee = .endOfStream
                return nil
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 8192) else {
                status.pointee = .endOfStream
                return nil
            }
            do { try file.read(into: buf) } catch {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            if buf.frameLength == 0 {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buf
        }

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: 8192) else {
                throw AudioDecodeError.unsupportedFormat
            }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
            if let convError { throw AudioDecodeError.conversionFailed(convError.localizedDescription) }
            if outBuf.frameLength > 0 {
                result.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .error { throw AudioDecodeError.conversionFailed("convert error") }
        }
        return result
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add project.yml VoiceType/Services/AudioFileDecoder.swift VoiceTypeTests/AudioFileDecoderTests.swift
git commit -m "feat: 音频文件解码为 16k 单声道 (TDD)"
```

---

### Task 4: AsrService + 端到端识别测试

**Files:**
- Create: `VoiceType/Services/AsrService.swift`
- Create: `VoiceTypeTests/AsrServiceTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/AsrServiceTests.swift`**

```swift
import XCTest

@testable import VoiceType

final class AsrServiceTests: XCTestCase {
    static let testWav = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            ".cache/modelscope/hub/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch/asr_example_hotword.wav"
        )

    private func requireModels() throws {
        try XCTSkipUnless(
            ModelPaths.allPresent,
            "模型未安装，请先运行 scripts/export_model.sh")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.testWav.path),
            "测试音频不存在")
    }

    func testTranscribeChineseWav() async throws {
        try requireModels()
        let samples = try AudioFileDecoder.decode16kMono(url: Self.testWav)
        let service = AsrService()
        let text = try await service.transcribe(samples: samples)
        print("ASR 结果: \(text)")
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "应识别出中文文本，实际: \(text)")
    }

    func testTranscribeFileWithVad() async throws {
        try requireModels()
        let service = AsrService()
        let text = try await service.transcribeFile(url: Self.testWav) { _ in }
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "VAD 文件转写应有中文，实际: \(text)")
    }

    func testTranscribeThrowsWhenModelMissing() async {
        guard !ModelPaths.allPresent else { return }
        let service = AsrService()
        do {
            _ = try await service.transcribe(samples: [Float](repeating: 0, count: 16000))
            XCTFail("应抛出模型缺失错误")
        } catch {}
    }
}
```

- [ ] **Step 2: 运行测试确认编译失败（AsrService/ModelPaths 未定义）**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL

- [ ] **Step 3: 实现 `VoiceType/Services/AsrService.swift`**

```swift
import Foundation

enum AsrError: LocalizedError {
    case modelMissing
    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "识别模型未安装，请在项目目录运行 scripts/export_model.sh"
        }
    }
}

enum ModelPaths {
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/models", isDirectory: true)
    }
    static var asrModel: URL { modelsDir.appendingPathComponent("model.int8.onnx") }
    static var tokens: URL { modelsDir.appendingPathComponent("tokens.txt") }
    static var vadModel: URL { modelsDir.appendingPathComponent("silero_vad.onnx") }
    static var allPresent: Bool {
        [asrModel, tokens, vadModel].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

/// SenseVoice 离线识别服务。推理在专用串行队列执行，模型常驻内存。
final class AsrService: @unchecked Sendable {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let queue = DispatchQueue(label: "com.catsonkeyboard.voicetype.asr", qos: .userInitiated)

    /// 预热：后台加载模型（App 启动时调用）
    func warmUp() {
        queue.async { _ = try? self.loadedRecognizer() }
    }

    private func loadedRecognizer() throws -> SherpaOnnxOfflineRecognizer {
        if let recognizer { return recognizer }
        guard ModelPaths.allPresent else { throw AsrError.modelMissing }
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: ModelPaths.asrModel.path,
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: ModelPaths.tokens.path,
            numThreads: 4,
            senseVoice: senseVoice
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        let r = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = r
        return r
    }

    /// 单段音频转写（16kHz 单声道）
    func transcribe(samples: [Float], sampleRate: Int = 16000) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try self.loadedRecognizer()
                    let text = r.decode(samples: samples, sampleRate: sampleRate).text
                    cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 文件转写：解码 → silero VAD 分段 → 逐段识别，段间换行
    func transcribeFile(
        url: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try self.loadedRecognizer()
                    guard ModelPaths.allPresent else { throw AsrError.modelMissing }
                    let silero = sherpaOnnxSileroVadModelConfig(
                        model: ModelPaths.vadModel.path,
                        threshold: 0.5,
                        minSilenceDuration: 0.5,
                        minSpeechDuration: 0.25,
                        windowSize: 512,
                        maxSpeechDuration: 20
                    )
                    var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)
                    let vad = SherpaOnnxVoiceActivityDetectorWrapper(
                        config: &vadConfig, buffer_size_in_seconds: 120)

                    var pieces: [String] = []
                    func drainSegments() {
                        while !vad.isEmpty() {
                            let seg = vad.front()
                            let text = r.decode(samples: seg.samples).text
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { pieces.append(text) }
                            vad.pop()
                        }
                    }

                    let window = 512
                    var i = 0
                    while i < samples.count {
                        let end = min(i + window, samples.count)
                        vad.acceptWaveform(samples: Array(samples[i..<end]))
                        drainSegments()
                        i = end
                        onProgress(Double(i) / Double(max(samples.count, 1)))
                    }
                    vad.flush()
                    drainSegments()
                    cont.resume(returning: pieces.joined(separator: "\n"))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`，日志含 `ASR 结果: <中文文本>`。人工确认识别文本合理。

- [ ] **Step 5: Commit**

```bash
git add VoiceType/Services/AsrService.swift VoiceTypeTests/AsrServiceTests.swift
git commit -m "feat: SenseVoice 识别服务 + VAD 文件转写 (端到端测试)"
```

---

### Task 5: HotwordCorrector（TDD）

**Files:**
- Create: `VoiceType/Services/HotwordCorrector.swift`
- Create: `VoiceTypeTests/HotwordCorrectorTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/HotwordCorrectorTests.swift`**

```swift
import XCTest

@testable import VoiceType

final class HotwordCorrectorTests: XCTestCase {
    func testPinyinConversion() {
        XCTAssertEqual(HotwordCorrector.pinyin(of: "朗诗德"), "langshide")
        XCTAssertEqual(HotwordCorrector.pinyin(of: "狼视得"), "langshide")
    }

    func testCorrectsHomophone() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let result = corrector.correct("我买了一台狼视得净水器")
        XCTAssertEqual(result, "我买了一台朗诗德净水器")
    }

    func testNearMissWithinThreshold() {
        // 「森派」vs「盛派」：shenpai vs shengpai，编辑距离 1，阈值内应纠正
        let corrector = HotwordCorrector(hotwords: ["盛派"])
        let result = corrector.correct("森派公司发布了新品")
        XCTAssertEqual(result, "盛派公司发布了新品")
    }

    func testDoesNotTouchUnrelatedText() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let text = "今天天气很好，我们去公园散步。"
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testDoesNotTouchEnglishAndDigits() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let text = "The price is 123 dollars."
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testEmptyHotwordsNoOp() {
        let corrector = HotwordCorrector(hotwords: [])
        XCTAssertEqual(corrector.correct("随便什么文本"), "随便什么文本")
    }

    func testExactMatchUnchanged() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        XCTAssertEqual(corrector.correct("朗诗德净水器很好"), "朗诗德净水器很好")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL（cannot find 'HotwordCorrector'）

- [ ] **Step 3: 实现 `VoiceType/Services/HotwordCorrector.swift`**

```swift
import Foundation

/// 识别结果后处理热词纠正：对文本按热词字数开滑窗，
/// 窗口拼音与热词拼音编辑距离 ≤ ⌈拼音长度×20%⌉（至少 1）即替换。
/// 仅处理 CJK 字符窗口（拼音方案对英文无意义）。
struct HotwordCorrector {
    private let entries: [(chars: [Character], pinyin: String)]

    init(hotwords: [String]) {
        entries = hotwords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy(Self.isCJK) }
            .map { (Array($0), Self.pinyin(of: $0)) }
            .filter { !$0.1.isEmpty }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
    }

    func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        var chars = Array(text)
        for (target, targetPinyin) in entries {
            let n = target.count
            guard chars.count >= n else { continue }
            let maxDistance = max(1, Int((Double(targetPinyin.count) * 0.2).rounded(.up)))
            var i = 0
            while i + n <= chars.count {
                let window = Array(chars[i..<(i + n)])
                if window == target {
                    i += n
                    continue
                }
                guard window.allSatisfy(Self.isCJK) else {
                    i += 1
                    continue
                }
                let windowPinyin = Self.pinyin(of: String(window))
                if Self.levenshtein(targetPinyin, windowPinyin) <= maxDistance {
                    chars.replaceSubrange(i..<(i + n), with: target)
                    i += n
                } else {
                    i += 1
                }
            }
        }
        return String(chars)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`。若 `testNearMissWithinThreshold` 失败，先打印实际拼音与距离再调整用例（阈值算法保持不变，用例中的词允许替换为其他真实近音词）。

- [ ] **Step 5: Commit**

```bash
git add VoiceType/Services/HotwordCorrector.swift VoiceTypeTests/HotwordCorrectorTests.swift
git commit -m "feat: 拼音模糊热词纠正 (TDD)"
```

---

### Task 6: HistoryStore（SwiftData，TDD）

**Files:**
- Create: `VoiceType/Services/HistoryStore.swift`
- Create: `VoiceTypeTests/HistoryStoreTests.swift`

- [ ] **Step 1: 写失败测试 `VoiceTypeTests/HistoryStoreTests.swift`**

```swift
import SwiftData
import XCTest

@testable import VoiceType

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func makeStore(maxRecords: Int = 200) throws -> HistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TranscriptRecord.self, configurations: config)
        return HistoryStore(context: container.mainContext, maxRecords: maxRecords)
    }

    func testAddAndFetch() throws {
        let store = try makeStore()
        store.add(text: "你好世界", durationSeconds: 1.2, source: "dictation")
        let records = store.recent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.text, "你好世界")
    }

    func testRecentIsNewestFirst() throws {
        let store = try makeStore()
        store.add(text: "第一条", durationSeconds: 1, source: "dictation")
        store.add(text: "第二条", durationSeconds: 1, source: "dictation")
        XCTAssertEqual(store.recent(limit: 10).first?.text, "第二条")
    }

    func testTrimToMaxRecords() throws {
        let store = try makeStore(maxRecords: 5)
        for i in 1...8 { store.add(text: "记录\(i)", durationSeconds: 1, source: "dictation") }
        XCTAssertEqual(store.recent(limit: 100).count, 5)
        XCTAssertEqual(store.recent(limit: 100).first?.text, "记录8")
    }

    func testDelete() throws {
        let store = try makeStore()
        store.add(text: "要删除", durationSeconds: 1, source: "file")
        store.delete(store.recent(limit: 1)[0])
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: FAIL

- [ ] **Step 3: 实现 `VoiceType/Services/HistoryStore.swift`**

```swift
import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var source: String  // "dictation" | "file"

    init(text: String, createdAt: Date = .now, durationSeconds: Double = 0, source: String = "dictation") {
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.source = source
    }
}

@MainActor
final class HistoryStore {
    private let context: ModelContext
    private let maxRecords: Int

    init(context: ModelContext, maxRecords: Int = 200) {
        self.context = context
        self.maxRecords = maxRecords
    }

    func add(text: String, durationSeconds: Double, source: String) {
        context.insert(
            TranscriptRecord(text: text, durationSeconds: durationSeconds, source: source))
        trim()
        try? context.save()
    }

    func recent(limit: Int = 50) -> [TranscriptRecord] {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func delete(_ record: TranscriptRecord) {
        context.delete(record)
        try? context.save()
    }

    func clear() {
        try? context.delete(model: TranscriptRecord.self)
        try? context.save()
    }

    private func trim() {
        let all = (try? context.fetch(
            FetchDescriptor<TranscriptRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        for record in all.dropFirst(maxRecords) {
            context.delete(record)
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add VoiceType/Services/HistoryStore.swift VoiceTypeTests/HistoryStoreTests.swift
git commit -m "feat: SwiftData 转写历史 (TDD)"
```

---

### Task 7: SettingsStore + AudioRecorder + TextInjector + HotkeyManager

系统集成类组件（麦克风/辅助功能/Carbon 事件），无法在单测中自动验证，本任务保证编译通过，行为在 Task 12 人工验收。

**Files:**
- Create: `VoiceType/Services/SettingsStore.swift`
- Create: `VoiceType/Services/AudioRecorder.swift`
- Create: `VoiceType/Services/TextInjector.swift`
- Create: `VoiceType/Services/HotkeyManager.swift`

- [ ] **Step 1: 实现 `VoiceType/Services/SettingsStore.swift`**

```swift
import Foundation

enum SettingsStore {
    private static let defaults = UserDefaults.standard

    static var hotwordsText: String {
        get { defaults.string(forKey: "hotwordsText") ?? "" }
        set { defaults.set(newValue, forKey: "hotwordsText") }
    }

    static var hotwords: [String] {
        hotwordsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var keyCombo: HotkeyManager.KeyCombo {
        get {
            guard let data = defaults.data(forKey: "keyCombo"),
                let combo = try? JSONDecoder().decode(HotkeyManager.KeyCombo.self, from: data)
            else { return .default }
            return combo
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "keyCombo")
        }
    }
}
```

- [ ] **Step 2: 实现 `VoiceType/Services/HotkeyManager.swift`**

```swift
import AppKit
import Carbon.HIToolbox

/// Carbon 全局快捷键。App 生命周期内单例，切换组合键时先注销再注册。
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct KeyCombo: Codable, Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32
        var display: String

        static let `default` = KeyCombo(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(optionKey),
            display: "⌥Space")
    }

    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register(_ combo: KeyCombo) {
        unregister()
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5654_5950), id: 1)  // 'VTYP'
        RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
    }

    /// Cocoa 修饰键 → Carbon 修饰键
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
```

- [ ] **Step 3: 实现 `VoiceType/Services/AudioRecorder.swift`**

```swift
import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case formatUnsupported

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "没有可用的麦克风输入设备"
        case .formatUnsupported: return "麦克风音频格式不受支持"
        }
    }
}

/// AVAudioEngine 麦克风采集，tap 内实时重采样为 16kHz 单声道 Float32。
/// start/stop 需在主线程调用；采样累积在音频线程，用锁保护。
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()

    /// 音频电平回调（0~1），主线程派发，供 HUD 显示
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let srcFormat = input.outputFormat(forBus: 0)
        guard srcFormat.sampleRate > 0, srcFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw RecorderError.formatUnsupported
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: srcFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 返回本次录音的全部 16k 采样
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = dstFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuf.frameLength > 0 else { return }

        let chunk = UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(max(chunk.count, 1))).squareRoot()
        let level = min(1, rms * 12)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}
```

- [ ] **Step 4: 实现 `VoiceType/Services/TextInjector.swift`**

```swift
import AppKit
import ApplicationServices

enum InjectResult {
    case injected
    case copiedToClipboard
}

/// 把文本注入前台 App 光标处：写剪贴板 → 合成 ⌘V → 稍后恢复原剪贴板。
/// 需要辅助功能权限；未授权时降级为仅复制。
enum TextInjector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 触发系统的辅助功能授权引导弹窗
    static func promptForAccessibility() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func inject(_ text: String) -> InjectResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted,
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),  // kVK_ANSI_V
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return .copiedToClipboard  // 文本留在剪贴板，由调用方提示手动粘贴
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return .injected
    }
}
```

- [ ] **Step 5: 构建 + 全量测试**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add VoiceType/Services
git commit -m "feat: 设置存储、录音、文本注入、全局快捷键"
```

---

### Task 8: AppState + DictationController + RecordingHUD

**Files:**
- Create: `VoiceType/App/AppState.swift`
- Create: `VoiceType/Services/DictationController.swift`
- Create: `VoiceType/UI/RecordingHUD.swift`

- [ ] **Step 1: 实现 `VoiceType/App/AppState.swift`**

```swift
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    enum FileJob: Equatable {
        case idle
        case running(progress: Double)
        case done(text: String)
        case failed(String)
    }

    var phase: Phase = .idle
    var micLevel: Float = 0
    /// HUD 上的一次性提示（如“已复制到剪贴板”），显示后由 HUDController 清除
    var hudMessage: String?
    var fileJob: FileJob = .idle
    var modelsReady: Bool = ModelPaths.allPresent

    func refreshModelsReady() {
        modelsReady = ModelPaths.allPresent
    }
}
```

- [ ] **Step 2: 实现 `VoiceType/Services/DictationController.swift`**

```swift
import AppKit
import Foundation

/// 听写编排：快捷键/面板触发 → 录音 → 识别 → 热词纠正 → 注入 → 历史。
@MainActor
final class DictationController {
    static let maxRecordingSeconds: TimeInterval = 300
    static let minRecordingSeconds: Double = 0.5

    let state: AppState
    let asr: AsrService
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private var capTimer: Timer?

    init(state: AppState, asr: AsrService, history: HistoryStore) {
        self.state = state
        self.asr = asr
        self.history = history
    }

    /// 快捷键与面板按钮共用的入口：idle→开始，recording→结束
    func toggle() {
        switch state.phase {
        case .idle, .error:
            startRecording()
        case .recording:
            Task { await finishRecording() }
        case .transcribing:
            break  // 识别中忽略触发
        }
    }

    private func startRecording() {
        state.refreshModelsReady()
        guard state.modelsReady else {
            state.phase = .error(AsrError.modelMissing.localizedDescription)
            HUDController.shared.flash("模型未安装，请查看设置", state: state)
            return
        }
        Task {
            guard await AudioRecorder.requestPermission() else {
                state.phase = .error("麦克风未授权")
                HUDController.shared.flash("麦克风未授权，请在系统设置中允许", state: state)
                return
            }
            do {
                recorder.onLevel = { [weak self] level in
                    self?.state.micLevel = level
                }
                try recorder.start()
                state.phase = .recording
                HUDController.shared.show(state: state)
                capTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.maxRecordingSeconds, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in await self?.finishRecording() }
                }
            } catch {
                state.phase = .error(error.localizedDescription)
                HUDController.shared.flash(error.localizedDescription, state: state)
            }
        }
    }

    private func finishRecording() async {
        guard state.phase == .recording else { return }
        capTimer?.invalidate()
        capTimer = nil
        let samples = recorder.stop()
        let duration = Double(samples.count) / 16000.0
        guard duration >= Self.minRecordingSeconds else {
            state.phase = .idle
            HUDController.shared.hide()
            return
        }
        state.phase = .transcribing
        do {
            var text = try await asr.transcribe(samples: samples)
            text = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
            guard !text.isEmpty else {
                state.phase = .idle
                HUDController.shared.hide()
                return
            }
            history.add(text: text, durationSeconds: duration, source: "dictation")
            let result = TextInjector.inject(text)
            state.phase = .idle
            switch result {
            case .injected:
                HUDController.shared.hide()
            case .copiedToClipboard:
                HUDController.shared.flash("已复制到剪贴板，请按 ⌘V 粘贴", state: state)
            }
        } catch {
            state.phase = .error(error.localizedDescription)
            HUDController.shared.flash("识别失败：\(error.localizedDescription)", state: state)
        }
    }

    /// 面板文件转写入口
    func transcribeFile(url: URL) {
        if case .running = state.fileJob { return }
        state.refreshModelsReady()
        guard state.modelsReady else {
            state.fileJob = .failed(AsrError.modelMissing.localizedDescription)
            return
        }
        state.fileJob = .running(progress: 0)
        Task {
            do {
                let text = try await asr.transcribeFile(url: url) { [weak self] progress in
                    Task { @MainActor in
                        self?.state.fileJob = .running(progress: progress)
                    }
                }
                if text.isEmpty {
                    state.fileJob = .failed("未识别到语音内容")
                } else {
                    let corrected = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
                    history.add(text: corrected, durationSeconds: 0, source: "file")
                    state.fileJob = .done(text: corrected)
                }
            } catch {
                state.fileJob = .failed(error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 3: 实现 `VoiceType/UI/RecordingHUD.swift`**

```swift
import AppKit
import SwiftUI

/// 录音/识别状态悬浮窗：无边框、不抢焦点、置顶、所有空间可见。
@MainActor
final class HUDController {
    static let shared = HUDController()
    private var panel: NSPanel?
    private var flashTask: Task<Void, Never>?

    private init() {}

    func show(state: AppState) {
        flashTask?.cancel()
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: RecordingHUDView(state: state))
            panel = p
        }
        if let screen = NSScreen.main, let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 100))
        }
        panel?.orderFrontRegardless()
    }

    /// 显示一条短消息后自动隐藏
    func flash(_ message: String, state: AppState, seconds: Double = 2.0) {
        state.hudMessage = message
        show(state: state)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            state.hudMessage = nil
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct RecordingHUDView: View {
    var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let message = state.hudMessage {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text(message)
                    .lineLimit(1)
            } else {
                switch state.phase {
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    LevelBarsView(level: state.micLevel)
                    Text("录音中")
                        .foregroundStyle(.secondary)
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                    Text("识别中…")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(width: 240, height: 56)
    }
}

struct LevelBarsView: View {
    var level: Float
    private let barCount = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / Float(barCount) < level ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
```

- [ ] **Step 4: 构建 + 全量测试**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add VoiceType/App/AppState.swift VoiceType/Services/DictationController.swift VoiceType/UI/RecordingHUD.swift
git commit -m "feat: 听写状态机、编排控制器与录音 HUD"
```

---

### Task 9: App 组装 + 菜单栏面板 UI

**Files:**
- Create: `VoiceType/App/AppDependencies.swift`
- Create: `VoiceType/UI/PanelView.swift`
- Modify: `VoiceType/App/VoiceTypeApp.swift`（替换 Task 1 的临时版）

- [ ] **Step 1: 实现 `VoiceType/App/AppDependencies.swift`**

```swift
import Foundation
import Observation
import SwiftData

/// 组装全部服务，作为 environment 注入视图树。
@MainActor
@Observable
final class AppDependencies {
    let state: AppState
    let container: ModelContainer
    let history: HistoryStore
    let dictation: DictationController
    let asr: AsrService

    init() {
        state = AppState()
        container = try! ModelContainer(for: TranscriptRecord.self)
        history = HistoryStore(context: container.mainContext)
        asr = AsrService()
        dictation = DictationController(state: state, asr: asr, history: history)

        HotkeyManager.shared.onHotkey = { [dictation] in dictation.toggle() }
        HotkeyManager.shared.register(SettingsStore.keyCombo)
        asr.warmUp()
    }
}
```

- [ ] **Step 2: 替换 `VoiceType/App/VoiceTypeApp.swift`**

```swift
import SwiftUI

@main
struct VoiceTypeApp: App {
    @State private var deps = AppDependencies()

    private var menuBarIcon: String {
        switch deps.state.phase {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .error: return "mic.slash"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(deps)
                .modelContainer(deps.container)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(deps)
        }
    }
}
```

注意：`SettingsView` 在 Task 10 实现；本任务先建占位文件（Step 3 面板中用 `SettingsLink` 打开），占位内容：

```swift
// VoiceType/UI/SettingsView.swift —— Task 10 替换
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Text("设置（开发中）").padding(40)
    }
}
```

- [ ] **Step 3: 实现 `VoiceType/UI/PanelView.swift`**

```swift
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse)
    private var records: [TranscriptRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            recordButton
            Divider()
            fileSection
            Divider()
            historySection
            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - 状态

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var statusColor: Color {
        if !deps.state.modelsReady { return .orange }
        switch deps.state.phase {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .blue
        case .error: return .orange
        }
    }

    private var statusText: String {
        if !deps.state.modelsReady {
            return "模型未安装：请运行 scripts/export_model.sh"
        }
        switch deps.state.phase {
        case .idle: return "就绪 · 按 \(SettingsStore.keyCombo.display) 开始听写"
        case .recording: return "录音中…再按快捷键结束"
        case .transcribing: return "识别中…"
        case .error(let message): return message
        }
    }

    // MARK: - 录音按钮

    private var recordButton: some View {
        Button {
            deps.dictation.toggle()
        } label: {
            Label(
                deps.state.phase == .recording ? "停止并转写" : "开始录音",
                systemImage: deps.state.phase == .recording ? "stop.circle.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(deps.state.phase == .recording ? .red : .accentColor)
        .disabled(deps.state.phase == .transcribing || !deps.state.modelsReady)
        .padding(12)
    }

    // MARK: - 文件转写

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch deps.state.fileJob {
            case .idle:
                fileDropArea(prompt: "拖入音频文件转写 (wav/mp3/m4a)")
            case .running(let progress):
                ProgressView(value: progress) {
                    Text("文件转写中… \(Int(progress * 100))%")
                        .font(.caption)
                }
            case .done(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    HStack {
                        Button("复制结果") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("完成") { deps.state.fileJob = .idle }
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("重试") { deps.state.fileJob = .idle }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    private func fileDropArea(prompt: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("选择文件…") { pickFile() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in deps.dictation.transcribeFile(url: url) }
            }
            return true
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            deps.dictation.transcribeFile(url: url)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近转写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !records.isEmpty {
                    Button("清空") { deps.history.clear() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if records.isEmpty {
                Text("暂无记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(records.prefix(20)) { record in
                            HistoryRow(record: record) {
                                deps.history.delete(record)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.text)
                    .font(.callout)
                    .lineLimit(2)
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
```

- [ ] **Step 4: 构建 + 全量测试**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add VoiceType/App VoiceType/UI
git commit -m "feat: App 组装与菜单栏面板（录音/历史/文件转写）"
```

---

### Task 10: 设置窗口（快捷键/热词/自启/权限/模型状态）

**Files:**
- Create: `VoiceType/UI/KeyComboRecorder.swift`
- Modify: `VoiceType/UI/SettingsView.swift`（替换占位）

- [ ] **Step 1: 实现 `VoiceType/UI/KeyComboRecorder.swift`**

```swift
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 点击后捕获下一次带修饰键的按键，作为新的全局快捷键。
struct KeyComboRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyManager.KeyCombo

    func makeNSView(context: Context) -> KeyCaptureButton {
        let button = KeyCaptureButton(frame: .zero)
        button.title = combo.display
        button.onCapture = { combo = $0 }
        return button
    }

    func updateNSView(_ nsView: KeyCaptureButton, context: Context) {
        if !nsView.isCapturing {
            nsView.title = combo.display
        }
        nsView.onCapture = { combo = $0 }
    }
}

final class KeyCaptureButton: NSButton {
    var onCapture: ((HotkeyManager.KeyCombo) -> Void)?
    private(set) var isCapturing = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        title = "按下新快捷键…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil  // 吞掉事件
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            endCapture(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return  // 必须带修饰键，继续等待
        }
        let combo = HotkeyManager.KeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: HotkeyManager.carbonModifiers(from: flags),
            display: Self.display(flags: flags, event: event))
        endCapture(combo)
    }

    private func endCapture(_ combo: HotkeyManager.KeyCombo?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isCapturing = false
        if let combo {
            title = combo.display
            onCapture?(combo)
        }
    }

    private static func display(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            return event.charactersIgnoringModifiers?.uppercased()
                ?? "键码\(event.keyCode)"
        }
    }
}
```

- [ ] **Step 2: 替换 `VoiceType/UI/SettingsView.swift`**

```swift
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            HotwordSettingsView()
                .tabItem { Label("热词", systemImage: "character.book.closed") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var combo = SettingsStore.keyCombo
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var accessibilityTrusted = TextInjector.isTrusted

    var body: some View {
        Form {
            Section("听写快捷键") {
                LabeledContent("全局快捷键") {
                    KeyComboRecorder(combo: $combo)
                        .frame(width: 160)
                }
                .onChange(of: combo) { _, newValue in
                    SettingsStore.keyCombo = newValue
                    HotkeyManager.shared.register(newValue)
                }
            }

            Section("权限") {
                LabeledContent("辅助功能（注入文本必需）") {
                    if accessibilityTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("去授权…") {
                            TextInjector.promptForAccessibility()
                        }
                    }
                }
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("模型") {
                LabeledContent("SenseVoice + VAD") {
                    if deps.state.modelsReady {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("未安装", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !deps.state.modelsReady {
                    Text("请在项目目录运行 scripts/export_model.sh 后点击刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("打开模型目录") {
                        try? FileManager.default.createDirectory(
                            at: ModelPaths.modelsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ModelPaths.modelsDir)
                    }
                    Button("刷新状态") {
                        deps.state.refreshModelsReady()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accessibilityTrusted = TextInjector.isTrusted
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct HotwordSettingsView: View {
    @State private var text = SettingsStore.hotwordsText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行一个热词（人名、品牌、专业术语等，仅支持中文词）。识别后按拼音相似度自动纠正。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator))
                .onChange(of: text) { _, newValue in
                    SettingsStore.hotwordsText = newValue
                }
            Text("当前生效 \(SettingsStore.hotwords.count) 个热词")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }
}
```

- [ ] **Step 3: 构建 + 全量测试**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add VoiceType/UI
git commit -m "feat: 设置窗口（快捷键录制/热词/自启/权限/模型状态）"
```

---

### Task 11: build.sh + README

**Files:**
- Create: `scripts/build.sh`
- Create: `README.md`

- [ ] **Step 1: 写 `scripts/build.sh`**

```bash
#!/bin/bash
# 一键构建 Release 版并输出到 dist/VoiceType.app
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fetch_deps.sh
xcodegen
xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build

rm -rf dist
mkdir -p dist
cp -R build/Build/Products/Release/VoiceType.app dist/
echo
echo "构建完成: dist/VoiceType.app"
echo "安装: cp -R dist/VoiceType.app /Applications/"
```

- [ ] **Step 2: 写 `README.md`**

```markdown
# VoiceType

macOS 菜单栏语音转写工具。全局快捷键（默认 ⌥Space）随时听写，识别结果直接输入到光标位置。基于 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) + 阿里 FunASR [SenseVoiceSmall](https://modelscope.cn/models/iic/SenseVoiceSmall)（ONNX int8，本地推理，无网络依赖）。

## 功能

- 全局快捷键听写到光标（toggle：按一下开始，再按结束），SenseVoice 自带标点与数字归一化
- 状态栏面板：手动录音、转写历史（复制/删除）、音频文件拖拽转写（VAD 自动分段）
- 热词词表：拼音模糊匹配纠正专有名词
- 开机自启、快捷键自定义、录音悬浮 HUD

## 构建

前置：Xcode 15+、`brew install xcodegen`

    ./scripts/export_model.sh   # 一次性：导出 SenseVoice ONNX int8 + 下载 VAD（模型装到 ~/Library/Application Support/VoiceType/models/）
    ./scripts/build.sh          # 产出 dist/VoiceType.app
    cp -R dist/VoiceType.app /Applications/

模型导出借用 voice-flow 项目的 Python venv（复用本地 modelscope 缓存的权重，零下载）。若本地无缓存，脚本会自动从 modelscope 下载。

## 首次运行授权

1. **麦克风**：首次录音时系统弹窗，允许即可
2. **辅助功能**：注入文本到光标需要。设置 → 权限 → 去授权，在系统设置中勾选 VoiceType

未授权辅助功能时自动降级：结果复制到剪贴板，手动 ⌘V 粘贴。

## 开发

    xcodegen                       # 生成 VoiceType.xcodeproj
    open VoiceType.xcodeproj       # Xcode 开发
    xcodebuild -project VoiceType.xcodeproj -scheme VoiceType \
      -destination 'platform=macOS' test   # 跑测试
```

- [ ] **Step 3: 运行完整构建**

Run: `chmod +x scripts/build.sh && ./scripts/build.sh 2>&1 | tail -5`
Expected: `构建完成: dist/VoiceType.app`

- [ ] **Step 4: Commit**

```bash
git add scripts/build.sh README.md
git commit -m "chore: 一键构建脚本与 README"
```

---

### Task 12: 集成自测与人工验收

- [ ] **Step 1: 全量测试**

Run: `xcodebuild -project VoiceType.xcodeproj -scheme VoiceType -destination 'platform=macOS' test 2>&1 | grep -E "Test Suite|TEST"`
Expected: 全部 SUCCEEDED，AsrServiceTests 不被 skip（模型已装）。

- [ ] **Step 2: 启动 App 冒烟**

Run: `open dist/VoiceType.app && sleep 5 && pgrep -x VoiceType`
Expected: 输出 PID；状态栏出现麦克风图标。

- [ ] **Step 3: 留给用户的人工验收清单（写进交付说明，不自动执行）**

1. 点状态栏图标 → 面板"就绪"，绿点
2. 面板"开始录音"→ 说一句话 →"停止并转写"→ 历史出现带标点的结果（首次触发麦克风授权弹窗）
3. 设置 → 权限 → 去授权辅助功能
4. 在备忘录中按 ⌥Space 说话再按 ⌥Space → 文字出现在光标处，HUD 正常显示/消失
5. 拖一个 mp3 到面板 → 分段转写结果正确
6. 设置热词后说含近音词的话 → 被纠正
7. 开机自启开关无报错（App 在 /Applications 时生效最可靠）

- [ ] **Step 4: 最终提交**

```bash
git add -A
git commit -m "chore: v1 完成"
```
