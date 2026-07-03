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
  uv pip install -q --python "$VENV/bin/python" onnx onnxruntime onnxscript
  git clone -q --depth 1 https://github.com/FunAudioLLM/SenseVoice "$WORK/SenseVoice"
  # 兼容新版 torch：SinusoidalPositionEncoder.__init__ 缺 super().__init__()（上游 bug）
  "$VENV/bin/python" - "$WORK/SenseVoice/model.py" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = "def __init__(self, d_model=80, dropout_rate=0.1):\n        pass"
new = "def __init__(self, d_model=80, dropout_rate=0.1):\n        super().__init__()"
assert old in src, "SenseVoice model.py 结构变化，请人工检查补丁"
open(path, "w").write(src.replace(old, new))
PYEOF
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
