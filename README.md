# LocalMinutes（本地妙记）

A local macOS app for managing meeting/lecture recordings: each item ("妙记") is a local audio/video file plus an imported SRT. You get a click-to-seek transcript, search, speaker stats, and an AI summary ("智能纪要") generated with your own API key. Built from `minutes-clone-spec.md` v2.

> **Status:** this was written in a Linux container with no Swift toolchain, so **it has never been compiled**. All 35 Swift files pass a Swift grammar parser (tree-sitter), and I reviewed the code by hand for type and concurrency errors. Expect a handful of compiler errors on the first build. `.github/workflows/build.yml` builds it on a GitHub macOS runner if you push the repo.

## Build

Requirements: macOS 14+, Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open LocalMinutes.xcodeproj
```

Then press ⌘R. The project is set to "Sign to Run Locally". If you pick your own team under *Signing & Capabilities*, the Keychain stops asking for access to the API key after every rebuild.

Core unit tests (SRT parsing, paragraph merging, pairing, the LLM client, validation) run without Xcode:

```bash
swift test
```

## Layout

```
Sources/MinutesCore/        platform-independent logic (also compiled into the app)
  Models.swift              Cue / Paragraph / Speaker / Summary / Minute (§9.4)
  SRTParser.swift           encodings, tolerant parsing, speaker prefixes (§9.2)
  Paragraphs.swift          paragraph merging (§9.3), cue timeline + gap skipping (§3.4), speaker stats
  FilePairing.swift         title normalisation and media/SRT auto-pairing (§9.1.1)
  TimeFormat.swift          all time and date formats (§9.6)
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
  Settings/                 settings window and API form (§7.1)
Tests/MinutesCoreTests/     XCTest for the core
project.yml                 XcodeGen spec (sandbox entitlements, Info.plist)
```

## Where this differs from the spec, and why

- **Entitlements:** I used `files.user-selected.read-write` instead of `read-only`, because the export save panel needs write access. I added `files.bookmarks.app-scope`, because security-scoped bookmarks don't work inside the sandbox without it.
- **Anthropic defaults:** current Claude models reject `temperature`, and their thinking counts toward `max_tokens`. So the Anthropic preset turns temperature off, raises "最大输出 tokens" to 16000, and pre-fills the model `claude-opus-5-5`. You can change all three. For `api.anthropic.com` with a supported model, the request also sends `fallbacks: "default"` (beta header `server-side-fallback-2026-07-01`), so a request the model refuses is retried server-side on another model. If an endpoint rejects it with HTTP 400, the downgrade logic drops it. A response with `stop_reason: "refusal"` is shown as an error.
- **anthropic-version** defaults to `2023-06-01`, as the spec says, and can be edited in the Advanced section.
- **Speaker prefixes:** free-form `名字：` / `[名字]` / `名字 - ` prefixes only count when the same name appears at least twice in the file. Without this, lines like "注意：…" would each create a fake speaker. `说话人 N:` and `Speaker N:` always count.
- **Re-importing an SRT** keeps any names you gave speakers whose IDs still exist.
- **Avatars** for `说话人 N` show the number N rather than the first character, so speakers can be told apart.
- **Date from file name:** when a file name has `YYYY-MM-DD` but no time, the import time of day is used.
- **Default right tab** is 文字记录.

## Known limits

- Per-character highlighting is an estimate (elapsed / cue length × characters), because SRT only has cue-level timing. You can turn it off under Settings → 通用.
- Hover thumbnails come from `AVAssetImageGenerator` in 2-second buckets and are cached in memory only.
- The library's full-text search builds its index in the background the first time you search, so results from transcripts can take a moment to appear.
