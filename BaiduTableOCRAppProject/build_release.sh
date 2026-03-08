#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BaiduTableOCRApp"
SRC="$ROOT/BaiduTableOCRApp/App.swift"
PLIST="$ROOT/BaiduTableOCRApp/Info.plist"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
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
