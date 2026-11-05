# Bacon Minutes for Windows（培根妙记 Windows 版）

Electron port of the macOS app, kept feature-for-feature with it: folders, library stats, Feishu-style flip-down menus and confirmation dialogs, in-place title editing, nine UI languages, a custom app icon, the same AI summary prompt, an import review dialog (copy into the app or link), summaries that keep generating in the background, several summary versions per minute, starred models, and `.baconsummary` files that move between the Mac and Windows apps. The core logic in `src/core/` is a line-by-line port of `Sources/MinutesCore`.

The app is called 培根妙记 in the Chinese UI and Bacon Minutes everywhere else.

## Install

Every push builds an installer in GitHub Actions (job **windows**, artifact **BaconMinutes-windows**). Download `BaconMinutes-Setup-<version>-x64.exe` and run it (Windows on ARM runs it through x64 emulation). The installer is not code-signed, so SmartScreen shows "Windows protected your PC" the first time: click **More info → Run anyway**.

It installs over the older 本地妙记 build (same app id). On first launch the library moves from `%APPDATA%\本地妙记` to `%APPDATA%\BaconMinutes`.

## Develop

Requirements: Node.js 22. The build reads the Mac app's translation tables from `../App/Resources`, so work from a full checkout.

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

## Languages

简体中文, English, 日本語, 한국어, Español, Tiếng Việt, Français, Português and Русский, switched under Settings → General → App Language (default: follow Windows). The Chinese text in the code is the lookup key: `L('已选 {0} 项', n)`. `scripts/i18n.mjs` merges the Mac app's `Localizable.strings` with `src/i18n/windows.json` (text only Windows has, such as 资源管理器) into `src/i18n/generated.json` before every build and test run. `npm test` fails when a key used in the code lacks any of the eight translations.

## Layout

```
src/core/        platform-independent logic, unit-tested with node:test
  i18n.js          UI languages and L()
src/main/        Electron main process: library store and folders, settings, app icon, dialogs, LLM calls
src/preload/     the IPC bridge (whitelisted channels only)
src/renderer/    Preact UI
  transcriptView.js  whole transcript as plain DOM; highlights via the CSS Custom Highlight API
  detail.js          one open minute: playback ↔ transcript sync, search, summary jobs
  components/        list page, detail page, dialogs, settings, dropdown menus
src/i18n/        windows.json (Windows-only translations); generated.json is built
e2e/             Linux end-to-end harness (Xvfb + Playwright + mock LLM server)
```

## Windows-specific behaviour

| macOS version | Windows version |
|---|---|
| ⌘ shortcuts | Ctrl shortcuts: Ctrl+O import, Ctrl+Shift+O import folder, Ctrl+F search, Ctrl+[ or Alt+← back, Ctrl+1 / Ctrl+2 tabs, Ctrl+, settings, Delete moves selected items to the trash (after confirming) |
| API key in a file in the sandbox container | API key encrypted with Electron `safeStorage` (Windows DPAPI) in `%APPDATA%\BaconMinutes\settings.json` |
| Security-scoped bookmarks | Media is copied into the minute's folder by default; linked minutes keep the absolute path. Moved files show 原路径已找不到文件 with 重新检测路径 and 重新定位 |
| Bookmark resolution off the main thread | Linked files are checked in a separate file-check process (`fsWorker.js`) with a 4-second limit, so a NAS that has gone away shows 无法访问源文件所在位置 instead of freezing the app; copies into the app run in their own process too |
| Library in Application Support | `%APPDATA%\BaconMinutes\minutes\<id>\` (with `media\` for copied files and `summaries.json` for every summary version) and `folders.json` |
| Dock icon | Window and taskbar icon (Settings → General → App Icon) |
| Settings window (⌘,) | Settings dialog (Ctrl+,) |
| LLM requests via URLSession | `net.fetch` in the main process, which follows the system proxy settings |
| AVFoundation | Chromium media stack; files whose codecs Chromium can't decode (for example some HEVC `.mov`) show an error with 重新定位 |
| Native title bar | Hidden title bar with Windows' own min/max/close buttons drawn over the top-right corner |

The Start menu shortcut is named Bacon Minutes in every language; the window title follows the UI language.

## Tested

- `npm test`: 33 unit tests (SRT parsing incl. UTF-16/GB18030, paragraph merging, gap skipping, pairing, formats in several languages, LLM request shapes, downgrades against a local HTTP server, summary validation, model filtering, translation coverage, the `.baconsummary` format incl. a file written by the Mac app, starred models, and transcript hashes that match the Mac app).
- `e2e/run.sh` drives the real app under Xvfb with a 95-minute video and a 1,263-cue SRT: import and pairing, click-to-seek, drag-select, search, follow mode, skip-blank, CC, playback rates, summary generation against a mock server (including the HTTP 400 retry), chapter jumps, hover previews, speaker rename, trash/restore, missing media, settings, resume position, and dark mode.
- `e2e/parity.cjs` covers what the Mac app gained later: folders (create, inline rename, drag rows in, properties), library stats, hover and click menus, the trash confirmation, in-place title editing, cursors, and switching the UI language.
- `e2e/round7.cjs` (51 checks): straight vertical and horizontal folder drags, the import review dialog (pairs, guessed subtitles, thumbnails, skipped mkv/ass, copy vs link), 应用内 / 链接 labels, a moved file coming back with 重新检测路径, a share that never answers (the page opens at once, the main process keeps answering, the state settles to unreachable within the limit), importing a linked minute into the app, delete wording, deleting a folder with its minutes, a summary finishing after leaving the page, starring models, switching summary versions, exporting a `.baconsummary`, and importing it with and without matching metadata.
- Not tested here: anything that needs a real Windows desktop (the installer itself, title-bar buttons, native file dialogs, DPAPI, the taskbar icon), and real LLM providers.
