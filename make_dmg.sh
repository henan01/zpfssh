#!/bin/bash
set -e

APP_NAME="zpfssh"
SWIFT_BIN="/opt/homebrew/opt/swift/bin/swift"
VERSION="${1:-1.0.0}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="dmg_staging"

# ── Toolchain ──────────────────────────────────────────────────────────────
if [ ! -f "$SWIFT_BIN" ]; then
    SWIFT_BIN="$(which swift)"
fi
echo "==> 使用 Swift: $($SWIFT_BIN --version 2>&1 | head -1)"

# ── Build ──────────────────────────────────────────────────────────────────
echo "==> 编译 $APP_NAME ..."
$SWIFT_BIN build -c release

# ── Bundle .app ────────────────────────────────────────────────────────────
echo "==> 打包 .app bundle ..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/"
cp "Info.plist"                  "${APP_NAME}.app/Contents/"

ICON_SRC="Sources/zpfssh/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${APP_NAME}.app/Contents/Resources/"
fi

# ── Code-sign (ad-hoc) ─────────────────────────────────────────────────────
echo "==> 代码签名 (ad-hoc) ..."
codesign --force --deep --sign - --entitlements "zpfssh.entitlements" "${APP_NAME}.app"

# Embed Sparkle.framework for local DMG runs
SPARKLE_FRAMEWORK_SRC=""
if [ -d ".build/arm64-apple-macosx/release/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/arm64-apple-macosx/release/Sparkle.framework"
elif [ -d ".build/arm64-apple-macosx/release/Sparkle/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/arm64-apple-macosx/release/Sparkle/Sparkle.framework"
elif [ -d ".build/release/Sparkle.framework" ]; then
  SPARKLE_FRAMEWORK_SRC=".build/release/Sparkle.framework"
fi

if [ -n "$SPARKLE_FRAMEWORK_SRC" ]; then
  echo "==> Embed Sparkle.framework ..."
  mkdir -p "${APP_NAME}.app/Contents/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK_SRC" "${APP_NAME}.app/Contents/Frameworks/"
  mkdir -p "${APP_NAME}.app/Contents/MacOS"
  cp -R "$SPARKLE_FRAMEWORK_SRC" "${APP_NAME}.app/Contents/MacOS/"
  codesign --force --deep --sign - --entitlements "zpfssh.entitlements" "${APP_NAME}.app"
else
  echo "==> Skip Sparkle.framework embedding (not found in SwiftPM build output)."
fi

# ── DMG staging area ───────────────────────────────────────────────────────
echo "==> 创建 DMG ..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_NAME}.app" "${STAGING_DIR}/"

# Symlink to /Applications so users can drag-and-drop
ln -s /Applications "${STAGING_DIR}/Applications"

# ── Create DMG with hdiutil ────────────────────────────────────────────────
rm -f "${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_NAME}"

rm -rf "${STAGING_DIR}"

echo ""
echo "✅ DMG 已创建: $(pwd)/${DMG_NAME}"
echo ""
echo "分发给其他 Mac 时："
echo "  1. 发送 ${DMG_NAME} 给对方"
echo "  2. 对方双击挂载 DMG，把 ${APP_NAME}.app 拖入 Applications"
echo "  3. 首次运行右键 → 打开，或执行:"
echo "     xattr -cr /Applications/${APP_NAME}.app && open /Applications/${APP_NAME}.app"
