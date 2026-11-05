# Bacon Minutes（培根妙记）

A local macOS app for managing meeting and lecture recordings. Each item is a local audio or video file plus an imported SRT. You get a click-to-seek transcript, search, speaker stats, folders, and an AI summary generated with your own API key. Built from `minutes-clone-spec.md` v2.

## Media: in the app or linked

Dropping files or a folder opens a review dialog: one row per video with its thumbnail and paired SRT (each can be changed), plus a list of skipped formats such as mkv or ass. By default each file is copied into the app's library (`minutes/<id>/media/`), so moving or deleting the original does nothing to the minute. Ticking "只链接文件路径" keeps only a security-scoped bookmark to the original instead.

Each minute is labelled 应用内 or 链接. A linked minute can be imported into the app later (one way). When its file has moved, the player shows the original path with 重新检测路径 (checks again, mounting the network volume if needed) and 重新定位.

Media lookup never runs on the main thread: bookmark resolution and file checks happen on a background queue with a 4-second limit and never mount a volume when a minute opens. A NAS that has gone off the network shows 无法访问源文件所在位置 instead of freezing the app; while a check on a volume is overdue, further checks on it answer at once.

## Summaries

Generation belongs to the app, not to the page, so it keeps going after you go back to the list (the row shows 纪要生成中, and a toast says when it is done). Every generation is kept as a version in `summaries.json`, with a switcher in the summary tab. Models starred in Settings (☆ in the fetched model list or next to the model field) can be picked per minute; each runs on its own provider endpoint and key.

A summary can be exported as a `.baconsummary` file: JSON with the summary, the model and request parameters, and the source recording (file name, size, duration, SRT name, cue count and a hash of the cue text and timing). Dragging the file onto a minute imports it as another version; when the subtitles, media file or duration differ, the app lists the differences and asks first. Dropped on the list, the file finds its own minute by the subtitle hash. The Windows app reads and writes the same format.

The app is called 培根妙记 in the Chinese UI and Bacon Minutes everywhere else.

## Build

Requirements: macOS 14+, Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open BaconMinutes.xcodeproj
```

Then press ⌘R. The project is set to "Sign to Run Locally". 

`.github/workflows/build.yml` runs the checks below on a GitHub macOS runner and uploads a universal, ad-hoc signed `BaconMinutes.dmg`.

Core unit tests (SRT parsing, paragraph merging, pairing, the LLM client, validation, formatting) run without Xcode:

```bash
swift test
```

## Languages

The UI comes in 简体中文, English, 日本語, 한국어, Español, Tiếng Việt, Français, Português and Русский. Settings → General → App Language switches it at once. The default follows the system. Standard macOS menu items and open/save panels switch on the next launch.

The Chinese text in the code is the lookup key: `L("已选 {0} 项", count)`. The other languages live in `App/Resources/<code>.lproj/Localizable.strings`. A key can end in `@@context` when the same Chinese text needs different translations; the suffix is never shown. After adding or changing UI text, run:

```bash
python3 tools/check_l10n.py
```

It fails when a key is missing from a language or a translation drops a `{0}` placeholder. CI runs it too.

## Upgrading from LocalMinutes

The bundle identifier stays `com.localminutes.app`, because the sandbox container that holds the library and settings belongs to it. On first launch the app moves `Application Support/LocalMinutes` to `Application Support/BaconMinutes`.

API keys are stored in `api-keys.json` (mode 600) inside the app's sandbox container, not in the Keychain: with an unsigned build, every rebuild made macOS ask for the login password to read them. Keys saved in the Keychain by older builds are moved over once, silently; if macOS will not hand one over without a prompt, enter it again in Settings.

## Layout

```
Sources/MinutesCore/        platform-independent logic (also compiled into the app)
  Models.swift              Cue / Paragraph / Speaker / Summary / Minute (§9.4)
  SRTParser.swift           encodings, tolerant parsing, speaker prefixes (§9.2)
  Paragraphs.swift          paragraph merging (§9.3), cue timeline + gap skipping (§3.4), speaker stats
  FilePairing.swift         title normalisation and media/SRT auto-pairing (§9.1.1)
  TimeFormat.swift          all time and date formats (§9.6), per UI language
  Localization.swift        UI languages, L() lookup
  Exporter.swift            SRT / TXT / Markdown export
  SummaryFile.swift         .baconsummary export/import and metadata checks
  LLM/                      presets, request building, 400 downgrades, parsing, chunking, validation (§7, §8)
App/Sources/                SwiftUI + AppKit app
  AppModel.swift            navigation, import pipeline, keyboard shortcuts (§11)
  Common/MediaLocator.swift media lookup off the main thread with a time limit; copying into the app
  Import/                   import sheet and the batch import review dialog
  Library.swift             on-disk store under Application Support (§9.4)
  List/                     library page, trash, multi-select (§9.5)
  Detail/                   detail page, top bar, speakers / file info (§2, §4)
  Player/                   AVPlayer wrapper, overlay controls, segmented progress bar (§3)
  Transcript/               TextKit 1 NSTextView transcript, search, follow mode (§5)
  Summary/                  AI summary cards and states (§6), background jobs, summary files
  Settings/                 settings window, API form (§7.1), UI language choice
App/Resources/*.lproj/      Localizable.strings and localized app names
Tests/MinutesCoreTests/     XCTest for the core
project.yml                 XcodeGen spec (sandbox entitlements, Info.plist)
tools/check_l10n.py         translation completeness check
```

## Where this differs from the spec, and why

- **Entitlements:** I used `files.user-selected.read-write` instead of `read-only`, because the export save panel needs write access. I added `files.bookmarks.app-scope`, because security-scoped bookmarks don't work inside the sandbox without it.
- **Anthropic defaults:** current Claude models reject `temperature`, and their thinking counts toward `max_tokens`. So the Anthropic preset turns temperature off, raises "最大输出 tokens" to 16000, and pre-fills the model `claude-opus-5-5`. You can change all three. For `api.anthropic.com` with a supported model, the request also sends `fallbacks: "default"` (beta header `server-side-fallback-2026-07-01`), so a request the model refuses is retried server-side on another model. If an endpoint rejects it with HTTP 400, the downgrade logic drops it. A response with `stop_reason: "refusal"` is shown as an error.
- **anthropic-version** defaults to `2023-06-01`, as the spec says, and can be edited in the Advanced section.
- **Speaker prefixes:** free-form `名字：` / `[名字]` / `名字 - ` prefixes only count when the same name appears at least twice in the file. Without this, lines like "注意：…" would each create a fake speaker. `说话人 N:` and `Speaker N:` always count.
- **Re-importing an SRT** keeps any names you gave speakers whose IDs still exist.
- **Avatars** for `说话人 N` show the number N rather than the first character, so speakers can be told apart.
- **Date from file name:** when a file name has `YYYY-MM-DD` but no time, the import time of day is used.
- **Default right tab** is the transcript.
- **Trash** keeps items until you delete them; there is no automatic 30-day purge.

## Known limits

- Per-character highlighting is an estimate (elapsed / cue length × characters), because SRT only has cue-level timing. You can turn it off under Settings → General.
- Hover thumbnails come from `AVAssetImageGenerator` in 2-second buckets and are cached in memory only.
- The library's full-text search builds its index in the background the first time you search, so results from transcripts can take a moment to appear.
