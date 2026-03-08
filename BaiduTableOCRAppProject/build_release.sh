#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BaiduTableOCRApp"
SRC="$ROOT/BaiduTableOCRApp/App.swift"
PLIST="$ROOT/BaiduTableOCRApp/Info.plist"
ICON_SVG="$ROOT/icon.svg"
MENUBAR_ICON_SVG="$ROOT/MenuBarIconTemplate.svg"
ICON_BUILD_DIR="$ROOT/.iconbuild"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICON_BUILD_DIR"
cp "$PLIST" "$APP/Contents/Info.plist"

if [ -f "$ICON_SVG" ]; then
  rm -rf "$ICON_BUILD_DIR/AppIcon.iconset" "$ICON_BUILD_DIR/AppIcon.icns"
  qlmanage -t -s 1024 -o "$ICON_BUILD_DIR" "$ICON_SVG" >/dev/null 2>&1 || true
  THUMB="$ICON_BUILD_DIR/$(basename "$ICON_SVG").png"
  if [ -f "$THUMB" ]; then
    mkdir -p "$ICON_BUILD_DIR/AppIcon.iconset"
    sips -z 16 16     "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_16x16.png" >/dev/null
    sips -z 32 32     "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_32x32.png" >/dev/null
    sips -z 64 64     "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_128x128.png" >/dev/null
    sips -z 256 256   "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_256x256.png" >/dev/null
    sips -z 512 512   "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$THUMB" --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_512x512.png" >/dev/null
    cp "$THUMB" "$ICON_BUILD_DIR/AppIcon.iconset/icon_512x512@2x.png"
    iconutil -c icns "$ICON_BUILD_DIR/AppIcon.iconset" -o "$ICON_BUILD_DIR/AppIcon.icns"
    cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  fi
fi

if [ -f "$MENUBAR_ICON_SVG" ]; then
  npx -y sharp-cli     -i "$MENUBAR_ICON_SVG"     -o "$APP/Contents/Resources/MenuBarIconTemplate.png"     --density 288     resize 64 64 >/dev/null 2>&1 || true
fi
swiftc "$SRC" \
  -parse-as-library \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -framework Cocoa \
  -framework Carbon \
  -framework CryptoKit \
  -framework Security \
  -framework ScreenCaptureKit
chmod +x "$APP/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
rm -rf "$DEST_APP"
cp -R "$APP" "$DEST_APP"
codesign --force --deep --sign - "$DEST_APP" >/dev/null 2>&1 || true
echo "$DEST_APP"
