# VoiceType

**English** | [简体中文](README.zh-CN.md)

**VoiceType** is a menu bar dictation tool that turns messy speech into clean, publish-ready text — on-device by default. Runs on **macOS** (Swift/SwiftUI) and **Windows** (WPF/.NET, see [`windows/`](windows/)).

Press a global hotkey (default `⌥Space`) anywhere, speak naturally, and the transcribed text is typed straight into your cursor position. A local LLM then polishes the raw transcript in real time: filler words are removed, self-corrections are resolved ("meeting tomorrow afternoon… no wait, 9 AM" → "meeting tomorrow at 9 AM"), and spoken lists are auto-formatted into numbered bullets.

## Features

- **Switchable local models (v5)**: Settings → Recognition → Local model
  - **Fun-ASR-Nano-2512** (default, 0.8B int8, ~1GB): strongest Chinese-English code-switching and Chinese dialects; LLM decoder with context understanding and hallucination suppression
  - **Qwen3-ASR-0.6B** (~950MB): 30 languages + 22 Chinese dialects, song lyrics / rap recognition
  - **SenseVoiceSmall** (~230MB): lightweight and fastest, good for pure Chinese or English
  - Switching takes effect immediately; LLM models auto-segment dictations longer than 20s via VAD to avoid the max_total_len truncation
- **Smart polishing (v2)**: a local LLM (Ollama + Apple MLX backend) rewrites spoken fragments into fluent written text — removes filler words ("um", "uh", 呃/嗯/那个), applies self-corrections, and auto-formats enumerations into Markdown lists. Falls back to the raw transcript automatically whenever the LLM is unavailable — dictation is never blocked
- **Cloud ASR (v3, optional)**: switch to Alibaba Cloud Model Studio's Fun-ASR-Realtime for streaming recognition — live partial results in the HUD while you speak, near-instant final text on stop, automatic fallback to the local engine on any failure. API key stored in the macOS Keychain. Note: cloud mode sends audio to Alibaba Cloud
- **Meeting transcription with speaker diarization (v4)**: record a meeting from the mic (or import an audio file) and get a speaker-labeled transcript — pyannote segmentation + 3D-Speaker embeddings via sherpa-onnx, fully on-device. Rename speakers, export Markdown, and generate AI meeting minutes (topics / key points / decisions / action items) through your configured LLM
- **Hotkey dictation to cursor**: press once to start, again to stop; recognized text is injected at the cursor of whatever app you're in. Built-in punctuation and inverse text normalization
- **Menu bar panel**: manual recording, transcription history (copy / delete, polished + raw text kept), drag-and-drop audio file transcription with VAD segmentation
- **Hotword correction**: maintain a custom vocabulary; recognized text is corrected by pinyin fuzzy matching (great for names and domain terms)
- Launch at login, customizable hotkey, recording HUD

## Performance

On Apple Silicon: recognition is fully local via sherpa-onnx — SenseVoiceSmall finishes in ~0.3s, while Fun-ASR-Nano-2512 / Qwen3-ASR-0.6B (LLM decoders, higher accuracy for code-switching) typically take 1–3s depending on audio length; polishing adds ~0.4s (qwen3.5:4b-nvfp4 on Ollama's MLX backend). Local mode makes no network calls — audio and text never leave your Mac. Cloud ASR and cloud polishing are explicit opt-ins.

## Build

Prerequisites: Xcode 15+, `brew install xcodegen`

    ./scripts/export_model.sh                 # one-time: export SenseVoiceSmall + download the VAD model
    ./scripts/download_models.sh funasr-nano  # default model (~1GB); or qwen3 / all
    ./scripts/setup_diarization.sh            # optional: speaker diarization models (~35MB)
    ./scripts/build.sh                        # produces dist/VoiceType.app
    cp -R dist/VoiceType.app /Applications/

Models install to `~/Library/Application Support/VoiceType/models/`. `download_models.sh` prefers ModelScope (faster in China) and falls back to GitHub releases automatically.

The SenseVoice export script converts a locally cached FunASR checkpoint (ModelScope cache) using a Python venv — adjust the `VENV` path at the top of the script to your environment. Alternatively, download the prebuilt model from sherpa-onnx releases (`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`, ~230MB) and place `model.int8.onnx` + `tokens.txt` in the models directory.

## Windows

The Windows port lives in [`windows/`](windows/) — WPF on .NET 10, x64, feature-parity with the macOS app (same sherpa-onnx v1.13.3 runtime and model files, same cloud/polish protocols). Details: [`windows/README.md`](windows/README.md); porting notes: [`windows/MIGRATION.md`](windows/MIGRATION.md).

    powershell -ExecutionPolicy Bypass -File windows\scripts\download_models.ps1 funasr-nano
    powershell -ExecutionPolicy Bypass -File windows\scripts\build.ps1
    dotnet test windows\src\VoiceType.sln --filter Category!=Integration

Notable differences: the default hotkey is `Ctrl+Alt+Space` (Alt+Space is reserved by Windows), text injection uses `SendInput` with no permission prompt (elevated windows fall back to clipboard), and API keys are stored in Windows Credential Manager.

## Smart polishing (v2)

Polishing requires a local [Ollama](https://ollama.com) (≥0.19 for the MLX backend) and a model (downloaded by you, never automatically):

    ollama pull qwen3.5:4b-nvfp4   # 4GB, MLX/NVFP4 quantization

It works out of the box against `http://localhost:11434/v1`. In Settings → Polish you can toggle the feature, switch between "smart cleanup" and "formal rewrite" styles, pick another model, or point to any OpenAI-compatible endpoint (LM Studio, cloud APIs). History keeps the pre-polish transcript (right-click → copy raw text). Provider presets (Ollama / Alibaba Model Studio / DeepSeek / OpenAI) fill in the endpoint and a recommended model with one click.

## First-run permissions

1. **Microphone** — system prompt appears on first recording
2. **Accessibility** — required to inject text at the cursor. Settings → Permissions → Authorize, then enable VoiceType in System Settings

Without Accessibility permission VoiceType degrades gracefully: the result is copied to the clipboard and a HUD reminds you to paste with ⌘V.

## Development

    xcodegen                       # generate VoiceType.xcodeproj
    open VoiceType.xcodeproj       # develop in Xcode
    xcodebuild -project VoiceType.xcodeproj -scheme VoiceType \
      -destination 'platform=macOS' test   # run tests

Built with SwiftUI + SwiftData (macOS 14+), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) for on-device ASR, and the OpenAI-compatible chat protocol for pluggable LLM polishing. Design docs and implementation plans live in `docs/superpowers/`.
