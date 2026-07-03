#!/bin/bash
# 构建 → 安装到 /Applications → 清理多余构建副本 → 重启 App
# 避免 Spotlight 里出现多个 VoiceType（build/、dist/、DerivedData 的副本都会被清掉）
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

# 退出正在运行的实例（可能来自任意旧副本）
pkill -x VoiceType 2>/dev/null || true
sleep 1

# 安装：先删旧的再拷贝，避免 bundle 内残留
rm -rf /Applications/VoiceType.app
cp -R dist/VoiceType.app /Applications/

# 清理中间产物，Spotlight 只保留 /Applications 一份
rm -rf build dist
rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceType-*

open /Applications/VoiceType.app
echo
echo "已安装并启动 /Applications/VoiceType.app"
