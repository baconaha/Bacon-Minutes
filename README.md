# Bacon Minutes（培根妙记）

A local macOS app for managing meeting and lecture recordings. Each item is a local audio or video file plus an imported SRT. You get a click-to-seek transcript, search, speaker stats, folders, and an AI summary generated with your own API key. Built from `minutes-clone-spec.md` v2.

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
  LLM/                      presets, request building, 400 downgrades, parsing, chunking, validation (§7, §8)
App/Sources/                SwiftUI + AppKit app
  AppModel.swift            navigation, import pipeline, keyboard shortcuts (§11)
  Library.swift             on-disk store under Application Support (§9.4)
  List/                     library page, trash, multi-select (§9.5)
  Detail/                   detail page, top bar, speakers / file info (§2, §4)
  Player/                   AVPlayer wrapper, overlay controls, segmented progress bar (§3)
  Transcript/               TextKit 1 NSTextView transcript, search, follow mode (§5)
  Summary/                  AI summary cards and states (§6)
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
