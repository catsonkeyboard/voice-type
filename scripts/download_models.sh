#!/bin/bash
# 下载本地识别模型（int8）到 ~/Library/Application Support/VoiceType/models/
# 用法: ./scripts/download_models.sh [funasr-nano|qwen3|all]
#   funasr-nano  Fun-ASR-Nano-2512（默认，约 1GB）中英混杂/方言最强
#   qwen3        Qwen3-ASR-0.6B（约 950MB）30 语种 + 22 中文方言
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
[ -f "$DEST/funasr-nano/llm.int8.onnx" ] && FUNASR_OK=1
[ -f "$DEST/qwen3-asr/decoder.int8.onnx" ] && QWEN3_OK=1

case "$TARGET" in
  funasr-nano|all) [ "$FUNASR_OK" = 1 ] || fetch "sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2" "funasr-nano" ;;
esac
case "$TARGET" in
  qwen3|all) [ "$QWEN3_OK" = 1 ] || fetch "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2" "qwen3-asr" ;;
esac

if [ "$TARGET" != "funasr-nano" ] && [ "$TARGET" != "qwen3" ] && [ "$TARGET" != "all" ]; then
  echo "未知目标: $TARGET（可选 funasr-nano | qwen3 | all）" >&2
  exit 1
fi

ls -lh "$DEST" | grep -E 'funasr|qwen3|model.int8|tokens'
