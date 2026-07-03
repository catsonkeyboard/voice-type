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
