#!/bin/bash
set -e

APP_NAME="zpfssh"
SWIFT_BIN="/opt/homebrew/opt/swift/bin/swift"

# Fallback to system swift if brew swift not found
if [ ! -f "$SWIFT_BIN" ]; then
    SWIFT_BIN="$(which swift)"
fi

echo "==> 使用 Swift: $($SWIFT_BIN --version 2>&1 | head -1)"
echo "==> 编译 $APP_NAME ..."
$SWIFT_BIN build -c release

echo "==> 打包 .app bundle ..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_NAME.app/Contents/MacOS/"
cp "Info.plist" "$APP_NAME.app/Contents/"
cp "Sources/zpfssh/Resources/AppIcon.icns" "$APP_NAME.app/Contents/Resources/"

# Embed Sparkle.framework
# Sparkle is linked as a dynamic framework with an @rpath that (in your current build)
# can search relative to Contents/MacOS. To make local builds runnable, we embed it
# into both Locations.
SPARKLE_FRAMEWORK_SRC=""
if [ -d ".build/arm64-apple-macosx/release/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/arm64-apple-macosx/release/Sparkle.framework"
elif [ -d ".build/arm64-apple-macosx/release/Sparkle/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/arm64-apple-macosx/release/Sparkle/Sparkle.framework"
elif [ -d ".build/release/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/release/Sparkle.framework"
fi

if [ -z "$SPARKLE_FRAMEWORK_SRC" ]; then
  echo "ERROR: Could not find Sparkle.framework under SwiftPM build output."
  echo "Looked for: .build/arm64-apple-macosx/release/Sparkle.framework (and a few variants)."
  exit 1
fi

mkdir -p "$APP_NAME.app/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK_SRC" "$APP_NAME.app/Contents/Frameworks/"

mkdir -p "$APP_NAME.app/Contents/MacOS"
cp -R "$SPARKLE_FRAMEWORK_SRC" "$APP_NAME.app/Contents/MacOS/"

echo "==> 代码签名 (ad-hoc, with entitlements) ..."
codesign --force --deep --sign - --entitlements "zpfssh.entitlements" "$APP_NAME.app"

echo ""
echo "✅ 构建完成: $(pwd)/$APP_NAME.app"
echo ""
echo "分发给其他 Mac 时："
echo "  1. 拷贝 $APP_NAME.app 到目标 Mac 的 /Applications/"
echo "  2. 首次运行右键 → 打开，或执行:"
echo "     xattr -cr $APP_NAME.app && open $APP_NAME.app"
