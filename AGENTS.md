# AGENTS.md

## TableLens rebuild rule

When rebuilding or re-exporting the macOS app (`TableLens`) to `/Applications/TableLens.app`, always reset TCC permissions immediately after the rebuild so the new build does not reuse polluted permissions from an older app identity.

Use these commands after every rebuild:

```bash
pkill -f '/Applications/TableLens.app/Contents/MacOS/TableLens' || true

tccutil reset ScreenCapture local.utolaris.TableLens || true
tccutil reset Accessibility local.utolaris.TableLens || true
```

Then reopen the app:

```bash
open /Applications/TableLens.app
```

## Notes

- Always test the app from `/Applications/TableLens.app`.
- Do not mix permissions between older builds in other directories and the `/Applications` build.
