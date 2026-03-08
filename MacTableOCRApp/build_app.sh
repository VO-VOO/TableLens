#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BaiduTableOCRApp.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
swiftc "$ROOT/BaiduTableOCRApp.swift" \
  -o "$APP/Contents/MacOS/BaiduTableOCRApp" \
  -framework Cocoa \
  -framework Carbon \
  -framework CryptoKit \
  -framework Security \
  -framework ScreenCaptureKit
chmod +x "$APP/Contents/MacOS/BaiduTableOCRApp"
echo "$APP"
