# AGENTS.md

## BaiduTableOCRApp rebuild rule

When rebuilding or re-exporting the macOS app (`BaiduTableOCRApp`) to `/Applications/BaiduTableOCRApp.app`, always reset TCC permissions immediately after the rebuild so the new build does not reuse polluted permissions from an older app identity.

Use these commands after every rebuild:

```bash
pkill -f '/Applications/BaiduTableOCRApp.app/Contents/MacOS/BaiduTableOCRApp' || true

tccutil reset ScreenCapture local.utolaris.BaiduTableOCRApp || true
tccutil reset Accessibility local.utolaris.BaiduTableOCRApp || true
```

Then reopen the app:

```bash
open /Applications/BaiduTableOCRApp.app
```

## Notes

- Always test the app from `/Applications/BaiduTableOCRApp.app`.
- Do not mix permissions between older builds in other directories and the `/Applications` build.
