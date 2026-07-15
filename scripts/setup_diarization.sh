#!/bin/bash
# 下载说话人分离模型（pyannote 分段 + 3D-Speaker 声纹，共约 35MB）
set -euo pipefail
DEST="$HOME/Library/Application Support/VoiceType/models"
mkdir -p "$DEST"

if [ ! -f "$DEST/segmentation.onnx" ]; then
  curl -sL -o /tmp/pyannote-seg.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
  tar xjf /tmp/pyannote-seg.tar.bz2 -C /tmp
  cp /tmp/sherpa-onnx-pyannote-segmentation-3-0/model.onnx "$DEST/segmentation.onnx"
  rm -rf /tmp/pyannote-seg.tar.bz2 /tmp/sherpa-onnx-pyannote-segmentation-3-0
fi

if [ ! -f "$DEST/speaker-embedding.onnx" ]; then
  # 注意：官方 release tag 的 recongition 为历史遗留错拼
  curl -sL -o "$DEST/speaker-embedding.onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
fi
ls -lh "$DEST" | grep -E "segmentation|embedding"
