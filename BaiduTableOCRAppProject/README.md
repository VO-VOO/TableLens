# BaiduTableOCRApp

macOS menu bar app for Baidu table OCR.

## Structure
- `BaiduTableOCRApp/App.swift`: main app source
- `BaiduTableOCRApp/Info.plist`: app metadata
- `BaiduTableOCRApp.xcodeproj`: Xcode project
- `build_release.sh`: local build/export script (works without full Xcode)

## Build
```bash
./build_release.sh
```

Exports the app to `/Applications/BaiduTableOCRApp.app`.
