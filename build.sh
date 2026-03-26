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
cp "Sources/ZenSSH/Resources/AppIcon.icns" "$APP_NAME.app/Contents/Resources/"

echo "==> 代码签名 (ad-hoc, with entitlements) ..."
codesign --force --deep --sign - --entitlements "ZenSSH.entitlements" "$APP_NAME.app"

echo ""
echo "✅ 构建完成: $(pwd)/$APP_NAME.app"
echo ""
echo "分发给其他 Mac 时："
echo "  1. 拷贝 $APP_NAME.app 到目标 Mac 的 /Applications/"
echo "  2. 首次运行右键 → 打开，或执行:"
echo "     xattr -cr $APP_NAME.app && open $APP_NAME.app"
