#!/bin/bash
# scripts/run_tests.sh —— 受限 shell 环境（WorkBuddy 沙箱等）下的测试通道。
#
# 用法: ./scripts/run_tests.sh [XCTest 过滤器，如 PolishPromptTests / HotwordCorrectorTests / All]
#
# 为什么需要这个脚本（三类环境坑，2026-10-19 实测）：
#  1. xcodebuild test 的 testmanagerd IPC 在受限 shell 下握手挂起
#     （"test runner hung before establishing connection"），沙箱内外都一样；
#  2. swiftc 展开宏（@Observable/@Model）时用 sandbox-exec 给插件服务器套沙箱，
#     受限环境无法嵌套 sandbox → 必须加 -disable-sandbox；
#  3. 绕过 testmanagerd 的原生机制是 DYLD 注入 libXCTestBundleInject.dylib
#     让 App 宿主进程自己跑测试（xcodebuild 无 GUI 环境同款原理）。
#
# 脚本三步：
#  A. xcodebuild build-for-testing（带 -disable-sandbox 编译宏）
#  B. 补齐 App Frameworks 里的测试运行时（libXCTestSwiftSupport + _Testing_Foundation）
#  C. DYLD 注入启动 App 宿主跑测试（-XCTest 过滤）
#
# 注意：跑完 App 宿主可能不自动退出（菜单栏生命周期），脚本用 watchdog 兜底杀进程；
# 测试输出与 Xcode 完全同格式（Test Suite/Test Case 行）。
set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-All}"

PLATFORM="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer"
INJECT="$PLATFORM/usr/lib/libXCTestBundleInject.dylib"
SUPPORT="$PLATFORM/usr/lib/libXCTestSwiftSupport.dylib"
TF="$PLATFORM/Library/Frameworks/_Testing_Foundation.framework"

DD=$(ls -d ~/Library/Developer/Xcode/DerivedData/VoiceType-* 2>/dev/null | head -1)
if [ -z "$DD" ]; then
  echo "错误：找不到 DerivedData 目录（先跑一次 xcodegen + build）" >&2
  exit 1
fi
APP="$DD/Build/Products/Debug/VoiceType.app"
BUNDLE="$APP/Contents/PlugIns/VoiceTypeTests.xctest"

echo "[1/3] build-for-testing（宏编译需 -disable-sandbox）…"
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  xcodebuild -project VoiceType.xcodeproj -scheme VoiceType \
  -destination 'platform=macOS' build-for-testing \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  > /tmp/rt_build.log 2>&1
if [ $? -ne 0 ] || [ ! -d "$BUNDLE" ]; then
  echo "构建失败：" >&2
  grep -E "error:" /tmp/rt_build.log | head -10 >&2
  exit 1
fi

echo "[2/3] 补齐测试运行时依赖…"
mkdir -p "$APP/Contents/Frameworks"
[ -f "$APP/Contents/Frameworks/libXCTestSwiftSupport.dylib" ] || cp "$SUPPORT" "$APP/Contents/Frameworks/"
[ -d "$APP/Contents/Frameworks/_Testing_Foundation.framework" ] || cp -R "$TF" "$APP/Contents/Frameworks/"

echo "[3/3] Running tests (filter=$FILTER)..."
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  DYLD_INSERT_LIBRARIES="$INJECT" \
  XCTestBundlePath="$BUNDLE" \
  "$APP/Contents/MacOS/VoiceType" -XCTest "$FILTER" &
TPID=$!
# watchdog：测试套件输出 'Executed N tests' 后进程通常自退；最长等 5 分钟
for i in $(seq 1 300); do
  sleep 1
  kill -0 $TPID 2>/dev/null || break
done
kill $TPID 2>/dev/null
wait $TPID 2>/dev/null
echo "done"
