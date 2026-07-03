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
