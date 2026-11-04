import Foundation

enum MediaKind {
    case video, audio, subtitle, other
}

enum MediaTypes {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac"]
    static let subtitleExtensions: Set<String> = ["srt"]

    static var mediaExtensions: Set<String> { videoExtensions.union(audioExtensions) }

    static func kind(of url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if subtitleExtensions.contains(ext) { return .subtitle }
        return .other
    }

    static func isMedia(_ url: URL) -> Bool {
        let k = kind(of: url)
        return k == .video || k == .audio
    }

    static func isSubtitle(_ url: URL) -> Bool { kind(of: url) == .subtitle }
}

enum FilePairing {
    static let defaultSuffixes = ["_FeishuMinutes", "_Recording", "-Recording", " Recording", "_Minutes", "_录制", "_录音"]

    private static let leadingTimestamp = RegexPattern(#"^\d{13}_"#)

    /// §9.1.1 normalisation of a file name (without extension); also the default title (§9.6).
    static func normalizedTitle(_ baseName: String, suffixes: [String]) -> String {
        var s = baseName.trimmed
        if let end = leadingTimestamp.prefixMatchEnd(in: s) {
            s = String(s[end...])
        }
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where !suffix.isEmpty {
                if s.count > suffix.count, s.lowercased().hasSuffix(suffix.lowercased()) {
                    s = String(s.dropLast(suffix.count))
                    s = s.trimmed
                    changed = true
                }
            }
        }
        s = s.trimmed
        return s.isEmpty ? baseName.trimmed : s
    }

    static func pairingKey(_ url: URL, suffixes: [String]) -> String {
        normalizedTitle(url.deletingPathExtension().lastPathComponent, suffixes: suffixes).lowercased()
    }

    struct Pair: Hashable {
        var media: URL
        var subtitle: URL?
    }

    struct Suggestion: Hashable {
        var media: URL
        var subtitle: URL
    }

    struct Result {
        var pairs: [Pair]
        /// Media without a name match whose folder holds exactly one unclaimed SRT – ask the user.
        var suggestions: [Suggestion]
        /// SRTs that matched nothing and were not suggested.
        var unmatchedSubtitles: [URL]
    }

    static func pair(media: [URL], subtitles: [URL], suffixes: [String]) -> Result {
        var byKey: [String: [URL]] = [:]
        for s in subtitles { byKey[pairingKey(s, suffixes: suffixes), default: []].append(s) }
        var used = Set<URL>()
        var pairs: [Pair] = []
        var unmatchedMedia: [URL] = []

        for m in media {
            let key = pairingKey(m, suffixes: suffixes)
            if let candidate = byKey[key]?.first(where: { !used.contains($0) }) {
                used.insert(candidate)
                pairs.append(Pair(media: m, subtitle: candidate))
            } else {
                unmatchedMedia.append(m)
            }
        }

        var suggestions: [Suggestion] = []
        var remainingMedia: [URL] = []
        for m in unmatchedMedia {
            let folder = m.deletingLastPathComponent().standardizedFileURL
            let inFolder = subtitles.filter {
                !used.contains($0) && $0.deletingLastPathComponent().standardizedFileURL == folder
            }
            if inFolder.count == 1, let only = inFolder.first {
                used.insert(only)
                suggestions.append(Suggestion(media: m, subtitle: only))
            } else {
                remainingMedia.append(m)
            }
        }
        for m in remainingMedia { pairs.append(Pair(media: m, subtitle: nil)) }
        let unmatched = subtitles.filter { !used.contains($0) }
        return Result(pairs: pairs, suggestions: suggestions, unmatchedSubtitles: unmatched)
    }

    private static let datePattern = RegexPattern(#"((?:19|20)\d{2})-(\d{1,2})-(\d{1,2})(?:[ _T](\d{1,2})[-:.](\d{2}))?"#)

    /// `YYYY-MM-DD` (optionally followed by `HH-mm` / `HH:mm`) inside a file name.
    /// Without a time part the time of day of `fallback` is kept.
    static func dateFromFileName(_ name: String, fallback: Date, calendar: Calendar = .current) -> Date? {
        guard let g = datePattern.firstMatch(in: name),
              let y = g[1].flatMap({ Int($0) }), let mo = g[2].flatMap({ Int($0) }), let d = g[3].flatMap({ Int($0) }),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = mo
        comps.day = d
        if let h = g[4].flatMap({ Int($0) }), let mi = g[5].flatMap({ Int($0) }), h < 24, mi < 60 {
            comps.hour = h
            comps.minute = mi
        } else {
            let t = calendar.dateComponents([.hour, .minute], from: fallback)
            comps.hour = t.hour
            comps.minute = t.minute
        }
        return calendar.date(from: comps)
    }
}
