import Foundation

// MARK: - Parsing model output

struct RawTodo: Hashable {
    var content: String
    var owner: String
    var time: Double?
}

struct RawChapter: Hashable {
    var time: Double?
    var title: String
    var summary: String
}

struct RawSummary: Hashable {
    var overview: String = ""
    var keyPoints: [KeyPoint] = []
    var todos: [RawTodo] = []
    var chapters: [RawChapter] = []
    var keywords: [String] = []
}

enum SummaryParser {
    /// Removes `<think>…</think>` reasoning that some models put in the content.
    static func stripThinking(_ s: String) -> String {
        if let close = s.range(of: "</think>", options: .backwards) {
            return String(s[close.upperBound...])
        }
        if let open = s.range(of: "<think>") {
            return String(s[..<open.lowerBound])
        }
        return s
    }

    /// Code fences removed, then everything from the first `{` to the last `}`.
    static func extractJSONObject(_ s: String) -> String? {
        var t = stripThinking(s)
        t = t.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let first = t.firstIndex(of: "{"), let last = t.lastIndex(of: "}"), first < last else { return nil }
        return String(t[first...last])
    }

    struct ParseFailure: Error {}

    static func parse(_ text: String) throws -> (summary: RawSummary, json: String) {
        guard let json = extractJSONObject(text), let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseFailure()
        }
        var r = RawSummary()
        r.overview = string(obj["overview"] ?? obj["summary"])
        let kpAny = obj["key_points"] ?? obj["keyPoints"] ?? obj["keypoints"]
        if let arr = kpAny as? [Any] {
            for item in arr {
                if let d = item as? [String: Any] {
                    let title = string(d["title"])
                    let content = string(d["content"] ?? d["description"])
                    if !title.isEmpty || !content.isEmpty { r.keyPoints.append(KeyPoint(title: title, content: content)) }
                } else if let s = item as? String, !s.trimmed.isEmpty {
                    let parts = s.split(separator: "：", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        r.keyPoints.append(KeyPoint(title: parts[0].trimmed, content: parts[1].trimmed))
                    } else {
                        r.keyPoints.append(KeyPoint(title: "", content: s.trimmed))
                    }
                }
            }
        }
        if let arr = obj["todos"] as? [Any] {
            for item in arr {
                if let d = item as? [String: Any] {
                    let content = string(d["content"] ?? d["task"])
                    guard !content.isEmpty else { continue }
                    r.todos.append(RawTodo(content: content, owner: string(d["owner"]), time: time(d["time"])))
                } else if let s = item as? String, !s.trimmed.isEmpty {
                    r.todos.append(RawTodo(content: s.trimmed, owner: "", time: nil))
                }
            }
        }
        if let arr = obj["chapters"] as? [Any] {
            for item in arr {
                guard let d = item as? [String: Any] else { continue }
                let title = string(d["title"])
                guard !title.isEmpty else { continue }
                r.chapters.append(RawChapter(time: time(d["time"] ?? d["start"]), title: title,
                                             summary: string(d["summary"] ?? d["content"])))
            }
        }
        if let arr = obj["keywords"] as? [Any] {
            r.keywords = arr.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty }
        } else if let s = obj["keywords"] as? String {
            r.keywords = s.split(whereSeparator: { "，,、;；".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        guard !r.overview.isEmpty || !r.keyPoints.isEmpty || !r.chapters.isEmpty else { throw ParseFailure() }
        return (r, json)
    }

    static func string(_ any: Any?) -> String {
        if let s = any as? String { return s.trimmed }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(d) }
        return ""
    }

    static func time(_ any: Any?) -> Double? {
        if let s = any as? String { return TimeFormat.parseTimestamp(s) }
        if let i = any as? Int { return Double(i) }
        if let d = any as? Double { return d }
        return nil
    }
}

// MARK: - Input

struct SummaryInput {
    var title: String
    var duration: Double
    var speakerNames: [String]
    /// One line per paragraph: `[mm:ss] 名字：文本`.
    var lines: [String]
    var lineStarts: [Double]
    var foldedFullText: [UInt16]
    var language: OutputLanguage

    var useHours: Bool { TimeFormat.usesHours(totalDuration: duration) }

    static func make(title: String, duration: Double, transcript: Transcript, paragraphs: [Paragraph],
                     insertComma: Bool, language: OutputLanguage) -> SummaryInput {
        let total = duration > 0 ? duration : (transcript.cues.map(\.end).max() ?? 0)
        let hours = TimeFormat.usesHours(totalDuration: total)
        var lines: [String] = []
        var starts: [Double] = []
        var full = ""
        for p in paragraphs {
            let body = ParagraphBuilder.text(of: p, cues: transcript.cues, insertComma: insertComma)
            if body.trimmed.isEmpty { continue }
            let name = transcript.speakerName(p.speakerID)
            lines.append("[\(TimeFormat.timestamp(p.start, hours: hours))] \(name)：\(body)")
            starts.append(p.start)
            full += body + "\n"
        }
        let speakerIDs = Set(paragraphs.map(\.speakerID))
        let names = transcript.speakers.filter { speakerIDs.contains($0.id) }.map(\.name)
        return SummaryInput(title: title, duration: total, speakerNames: names, lines: lines,
                            lineStarts: starts, foldedFullText: TextFold.fold(full), language: language)
    }
}

enum SummaryProgress: Equatable {
    case single
    case part(Int, Int)
    case merging
}

// MARK: - Generator

final class SummaryGenerator {
    let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    /// Splits at paragraph boundaries so each chunk stays within `maxChars` characters.
    static func chunk(lines: [String], maxChars: Int) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        let limit = max(1000, maxChars)
        var ranges: [Range<Int>] = []
        var start = 0
        var count = 0
        for (i, line) in lines.enumerated() {
            let len = line.count + 1
            if count > 0 && count + len > limit {
                ranges.append(start..<i)
                start = i
                count = 0
            }
            count += len
        }
        ranges.append(start..<lines.count)
        return ranges
    }

    func generate(input: SummaryInput, config: LLMConfig, apiKey: String,
                  progress: @escaping @Sendable (SummaryProgress) -> Void) async throws -> SummaryDraft {
        guard !input.lines.isEmpty else { throw LLMError.notConfigured(L("文字记录为空，无法生成纪要")) }
        // The prompt is Chinese whatever the UI language is.
        let durationText = TimeFormat.duration(input.duration, language: .zhHans)
        let chunks = Self.chunk(lines: input.lines, maxChars: config.maxInputChars)

        if chunks.count <= 1 {
            progress(.single)
            let prompt = Prompts.user(language: input.language, title: input.title, durationText: durationText,
                                      speakers: input.speakerNames, lines: input.lines)
            let result = try await callJSON(user: prompt, config: config, apiKey: apiKey)
            return Self.validate(result.summary, input: input)
        }

        var partials: [String] = []
        for (i, r) in chunks.enumerated() {
            if Task.isCancelled { throw LLMError.cancelled }
            progress(.part(i + 1, chunks.count))
            let prompt = Prompts.user(language: input.language, title: input.title, durationText: durationText,
                                      speakers: input.speakerNames, lines: Array(input.lines[r]),
                                      part: (i + 1, chunks.count))
            let result = try await callJSON(user: prompt, config: config, apiKey: apiKey)
            partials.append(result.json)
        }
        if Task.isCancelled { throw LLMError.cancelled }
        progress(.merging)
        let merged = try await callJSON(user: Prompts.merge(language: input.language, partials: partials),
                                        config: config, apiKey: apiKey)
        return Self.validate(merged.summary, input: input)
    }

    private func callJSON(user: String, config: LLMConfig, apiKey: String) async throws -> (summary: RawSummary, json: String) {
        var prompt = user
        var attempt = 0
        while true {
            let response = try await client.complete(
                LLMRequest(system: Prompts.system, user: prompt, maxTokens: config.maxOutputTokens, jsonMode: true),
                config: config, apiKey: apiKey)
            if let parsed = try? SummaryParser.parse(response.text) {
                return parsed
            }
            if response.truncated { throw LLMError.truncated }
            if response.text.trimmed.isEmpty && attempt > 0 { throw LLMError.emptyResponse }
            if attempt >= 1 {
                throw LLMError.invalidJSON(String(response.text.trimmed.prefix(300)))
            }
            attempt += 1
            prompt = user + Prompts.jsonRetrySuffix
        }
    }

    // MARK: Validation (§7.5)

    /// Largest paragraph start whose displayed (floored) second is ≤ t; the first start if t is earlier.
    static func snap(_ t: Double?, starts: [Double]) -> Double {
        guard let first = starts.first else { return max(0, t ?? 0) }
        guard let t else { return first }
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid].rounded(.down) <= t + 0.001 { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? first : starts[lo - 1]
    }

    static func validate(_ raw: RawSummary, input: SummaryInput) -> SummaryDraft {
        let starts = input.lineStarts

        var chapters = raw.chapters.map {
            Chapter(time: snap($0.time, starts: starts), title: $0.title, summary: $0.summary)
        }
        chapters = chapters.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map { $0.element }
        chapters = dedupeByTime(chapters)
        if let first = starts.first, !chapters.isEmpty {
            chapters[0].time = first
            chapters = dedupeByTime(chapters)
        }

        let todos = raw.todos.map {
            TodoItem(content: $0.content, owner: $0.owner.isEmpty ? L("未指定") : $0.owner, time: snap($0.time, starts: starts))
        }

        var seen = Set<String>()
        var keywords: [String] = []
        for k in raw.keywords {
            let key = k.lowercased()
            guard !seen.contains(key) else { continue }
            guard TextFold.contains(input.foldedFullText, k) else { continue }
            seen.insert(key)
            keywords.append(k)
        }

        return SummaryDraft(overview: raw.overview,
                            keyPoints: raw.keyPoints.filter { !$0.title.isEmpty || !$0.content.isEmpty },
                            todos: todos, chapters: chapters, keywords: Array(keywords.prefix(12)))
    }

    private static func dedupeByTime(_ chapters: [Chapter]) -> [Chapter] {
        var out: [Chapter] = []
        for c in chapters {
            if let last = out.last, abs(last.time - c.time) < 0.001 { continue }
            out.append(c)
        }
        return out
    }
}
