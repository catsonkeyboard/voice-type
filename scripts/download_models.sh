#!/bin/bash
# 下载本地识别模型（int8）到 ~/Library/Application Support/VoiceType/models/
# 用法: ./scripts/download_models.sh [funasr-nano|qwen3|fire-red-ctc|all]
#   funasr-nano    Fun-ASR-Nano-2512（默认，约 1GB）中英混杂/方言最强
#   qwen3          Qwen3-ASR-0.6B（约 950MB）30 语种 + 22 中文方言
#   fire-red-ctc   FireRedASR2-CTC（约 1.7GB，实验档）中英混合 + 20 余种方言，CTC 解码 CPU 快
# SenseVoiceSmall 请用 ./scripts/export_model.sh 导出。
set -euo pipefail

DEST="$HOME/Library/Application Support/VoiceType/models"
TARGET="${1:-funasr-nano}"
mkdir -p "$DEST"

# ModelScope 国内快，GitHub 海外快；任一失败自动回退
fetch() {  # fetch <tarball-name> <out-dir>
  local name="$1" out="$2"
  local ms="https://modelscope.cn/models/csukuangfj/asr-models/resolve/master/$name"
  local gh="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$name"
  echo "下载 $name …"
  if ! curl -fL --retry 3 --connect-timeout 10 -o "/tmp/$name" "$ms"; then
    echo "ModelScope 失败，回退 GitHub …"
    curl -fL --retry 3 -o "/tmp/$name" "$gh"
  fi
  tar xjf "/tmp/$name" -C "$DEST"
  rm -rf "$DEST/$out"
  mv "$DEST/${name%.tar.bz2}" "$DEST/$out"
  rm "/tmp/$name"
  echo "✓ $out 安装完成"
}

FUNASR_OK=0
QWEN3_OK=0
FIRE_RED_OK=0
[ -f "$DEST/funasr-nano/llm.int8.onnx" ] && FUNASR_OK=1
[ -f "$DEST/qwen3-asr/decoder.int8.onnx" ] && QWEN3_OK=1
[ -f "$DEST/fire-red-ctc/model.int8.onnx" ] && FIRE_RED_OK=1

case "$TARGET" in
  funasr-nano|all) [ "$FUNASR_OK" = 1 ] || fetch "sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2" "funasr-nano" ;;
esac
case "$TARGET" in
  qwen3|all) [ "$QWEN3_OK" = 1 ] || fetch "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2" "qwen3-asr" ;;
esac
case "$TARGET" in
  fire-red-ctc|all) [ "$FIRE_RED_OK" = 1 ] || fetch "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2" "fire-red-ctc" ;;
esac

if [ "$TARGET" != "funasr-nano" ] && [ "$TARGET" != "qwen3" ] && [ "$TARGET" != "fire-red-ctc" ] && [ "$TARGET" != "all" ]; then
  echo "未知目标: $TARGET（可选 funasr-nano | qwen3 | fire-red-ctc | all）" >&2
  exit 1
fi

# FireRedASR2-CTC 包内主文件名可能不是 model.int8.onnx，统一重命名
if [ -d "$DEST/fire-red-ctc" ]; then
  if [ ! -f "$DEST/fire-red-ctc/model.int8.onnx" ] && [ -f "$DEST/fire-red-ctc/model.onnx" ]; then
    mv "$DEST/fire-red-ctc/model.onnx" "$DEST/fire-red-ctc/model.int8.onnx"
  fi
fi

ls -lh "$DEST" | grep -E 'funasr|qwen3|fire-red|model.int8|tokens'
