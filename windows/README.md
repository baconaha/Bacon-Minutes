# LocalMinutes for Windows（本地妙记 Windows 版）

Electron port of the macOS app, built from the same spec (`minutes-clone-spec.md` v2). It uses the same prompts and the same rules for parsing, pairing, merging and validation; the core logic in `src/core/` is a line-by-line port of `Sources/MinutesCore`.

## Install

Every push builds an installer in GitHub Actions (job **windows**, artifact **LocalMinutes-windows**). Download `LocalMinutes-Setup-<version>-x64.exe` and run it (Windows on ARM runs it through x64 emulation). The installer is not code-signed, so SmartScreen shows "Windows protected your PC" the first time: click **More info → Run anyway**.

## Develop

Requirements: Node.js 22.

```bash
npm ci
```

```bash
npm start
```

```bash
npm test
```

```bash
npm run dist
```

`npm run dist` writes the installer to `release/`. Building the NSIS installer needs Windows (or Wine).

## Layout

```
src/core/        platform-independent logic, unit-tested with node:test
src/main/        Electron main process: library store, settings, dialogs, LLM calls
src/preload/     the IPC bridge (whitelisted channels only)
src/renderer/    Preact UI
  transcriptView.js  whole transcript as plain DOM; highlights via the CSS Custom Highlight API
  detail.js          one open minute: playback ↔ transcript sync, search, summary jobs
e2e/             Linux end-to-end harness (Xvfb + Playwright + mock LLM server)
```

## Windows-specific behaviour

| macOS version | Windows version |
|---|---|
| ⌘ shortcuts | Ctrl shortcuts: Ctrl+O import, Ctrl+Shift+O import folder, Ctrl+F search, Ctrl+[ or Alt+← back, Ctrl+1 / Ctrl+2 tabs, Ctrl+, settings, Delete moves selected items to the trash |
| API key in Keychain | API key encrypted with Electron `safeStorage` (Windows DPAPI) in `%APPDATA%\本地妙记\settings.json` |
| Security-scoped bookmarks | Plain absolute paths; if the file is moved, the minute shows 媒体缺失 and offers 重新定位 |
| Library in Application Support | `%APPDATA%\本地妙记\minutes\<id>\` |
| LLM requests via URLSession | `net.fetch` in the main process, which follows the system proxy settings |
| AVFoundation | Chromium media stack; files whose codecs Chromium can't decode (for example some HEVC `.mov`) show an error with 重新定位 |
| Native title bar | Hidden title bar with Windows' own min/max/close buttons drawn over the top-right corner |

## Tested

- `npm test`: 22 unit tests (SRT parsing incl. UTF-16/GB18030, paragraph merging, gap skipping, pairing, formats, LLM request shapes, downgrades against a local HTTP server, summary validation).
- `e2e/run.sh` drives the real app under Xvfb with a 95-minute video and a 1,263-cue SRT. It checks import + pairing, click-to-seek, drag-select, search, follow mode, skip-blank, CC, playback rates, summary generation against a mock server (including the HTTP 400 retry), chapter jumps, hover previews, speaker rename, trash/restore, missing media, settings, resume position, and dark mode.
- Not tested here: anything that needs a real Windows desktop (the installer itself, title-bar buttons, native file dialogs, DPAPI), and real LLM providers.
