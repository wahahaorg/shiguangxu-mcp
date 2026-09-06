#!/bin/bash
# 时光番茄 Mac 应用打包脚本
# 产物: dist/时光番茄.app + zip + dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="时光番茄"
EXEC_NAME="ShiguangTomato"
VERSION="1.0.0"
BUILD_DIR="build"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

rm -rf "$BUILD_DIR" "$APP_BUNDLE"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "① 编译 Swift（arm64 + x86_64 通用二进制）…"
swiftc -O -target arm64-apple-macos13.0 -o "$BUILD_DIR/$EXEC_NAME-arm64" Sources/*.swift
swiftc -O -target x86_64-apple-macos13.0 -o "$BUILD_DIR/$EXEC_NAME-x86_64" Sources/*.swift
lipo -create -output "$BUILD_DIR/$EXEC_NAME" \
    "$BUILD_DIR/$EXEC_NAME-arm64" "$BUILD_DIR/$EXEC_NAME-x86_64"

echo "② 生成图标…"
swift scripts/make_icon.swift "$BUILD_DIR/icon_1024.png"
mkdir -p "$BUILD_DIR/AppIcon.iconset"
gen() { sips -z "$2" "$2" "$BUILD_DIR/icon_1024.png" --out "$BUILD_DIR/AppIcon.iconset/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "③ 组装 ${APP_BUNDLE}…"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign - "$APP_BUNDLE"

echo "④ 打包 zip / DMG…"
(cd "$DIST_DIR" && zip -qry "$APP_NAME-$VERSION-mac.zip" "$APP_NAME.app")
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO \
    "$DIST_DIR/$APP_NAME-$VERSION.dmg" >/dev/null

echo ""
echo "✅ 完成:"
ls -la "$DIST_DIR"
