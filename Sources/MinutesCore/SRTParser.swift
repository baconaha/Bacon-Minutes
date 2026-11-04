import Foundation

struct SRTParseResult {
    var cues: [Cue]
    var speakers: [Speaker]
}

enum SRTParseError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: return "文件中没有可识别的字幕条目（需要形如 00:00:01,000 --> 00:00:02,000 的时间行）"
        }
    }
}

/// SRT reader (§9.2): tolerant of encodings, missing/odd sequence numbers, blank-line noise,
/// formatting tags, overlapping and very short cues.
enum SRTParser {
    static let fallbackSpeakerID = "说话人 1"

    // MARK: Decoding

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE,
           let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return s
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF,
           let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return s
        }
        if let encoding = guessBOMlessUTF16(data), let s = String(data: data, encoding: encoding) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        #if canImport(Darwin)
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return s
        }
        #endif
        return String(decoding: data, as: UTF8.self)
    }

    /// SRT text is digit/ASCII heavy, so UTF-16 without BOM shows up as many zero bytes on one parity.
    private static func guessBOMlessUTF16(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(2000))
        guard sample.count >= 16 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, b) in sample.enumerated() where b == 0 {
            if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = Double(sample.count) / 2
        if Double(oddZeros) > half * 0.3 && evenZeros < oddZeros / 4 { return .utf16LittleEndian }
        if Double(evenZeros) > half * 0.3 && oddZeros < evenZeros / 4 { return .utf16BigEndian }
        return nil
    }

    // MARK: Parsing

    static func parse(data: Data) throws -> SRTParseResult {
        try parse(string: decode(data))
    }

    private struct RawCue {
        var start: Double
        var end: Double
        var lines: [String]
    }

    private static let timeLine = RegexPattern(
        #"^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?"#
    )
    private static let tagPattern = RegexPattern(#"<[^>]*>"#)
    private static let assPattern = RegexPattern(#"\{\\[^}]*\}"#)

    static func parse(string: String) throws -> SRTParseResult {
        var text = string
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        var raws: [RawCue] = []
        var current: RawCue?
        for line in lines {
            if line.contains("-->"), let times = parseTimeLine(line) {
                if var c = current {
                    c.lines = dropTrailingIndex(c.lines)
                    raws.append(c)
                }
                current = RawCue(start: times.0, end: times.1, lines: [])
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        if var c = current {
            c.lines = trimTrailingBlank(c.lines)
            raws.append(c)
        }
        guard !raws.isEmpty else { throw SRTParseError.empty }

        // Clean text and detect speaker prefixes.
        struct Pending {
            var start: Double
            var end: Double
            var text: String
            var candidate: SpeakerCandidate?
        }
        var pending: [Pending] = raws.map { raw in
            let content = joinTextLines(raw.lines)
            return Pending(start: raw.start, end: max(raw.start, raw.end), text: content,
                           candidate: detectSpeaker(in: content))
        }

        // Free-form "name:" prefixes only count when the same name occurs at least twice;
        // this keeps "注意：..." or "Note: ..." from becoming a speaker.
        var genericCounts: [String: Int] = [:]
        for p in pending {
            if let c = p.candidate, c.generic { genericCounts[c.id, default: 0] += 1 }
        }
        let allowSingletons = pending.count <= 2
        for i in pending.indices {
            guard let c = pending[i].candidate else { continue }
            if c.generic && !allowSingletons && (genericCounts[c.id] ?? 0) < 2 {
                pending[i].candidate = nil
            } else {
                pending[i].text = c.remainder
            }
        }

        // Stable sort by start time; overlapping cues are kept as they are.
        let order = pending.indices.sorted { a, b in
            (pending[a].start, a) < (pending[b].start, b)
        }
        var cues: [Cue] = []
        cues.reserveCapacity(order.count)
        var speakerOrder: [String] = []
        var seen = Set<String>()
        for (newIndex, oldIndex) in order.enumerated() {
            let p = pending[oldIndex]
            let speakerID = p.candidate?.id ?? fallbackSpeakerID
            if !seen.contains(speakerID) {
                seen.insert(speakerID)
                speakerOrder.append(speakerID)
            }
            cues.append(Cue(id: newIndex, start: p.start, end: p.end, text: p.text, speakerID: speakerID))
        }
        let speakers = speakerOrder.enumerated().map { idx, id in
            Speaker(id: id, name: id, colorHex: SpeakerPalette.color(at: idx))
        }
        return SRTParseResult(cues: cues, speakers: speakers)
    }

    static func parseTimeLine(_ line: String) -> (Double, Double)? {
        guard let g = timeLine.firstMatch(in: line) else { return nil }
        func seconds(_ h: String?, _ m: String?, _ s: String?, _ frac: String?) -> Double {
            let hh = Double(h ?? "0") ?? 0
            let mm = Double(m ?? "0") ?? 0
            let ss = Double(s ?? "0") ?? 0
            let ff = frac.flatMap { Double("0." + $0) } ?? 0
            return hh * 3600 + mm * 60 + ss + ff
        }
        let start = seconds(g[1], g[2], g[3], g[4])
        let end = seconds(g[5], g[6], g[7], g[8])
        return (start, end)
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmed.isEmpty }

    private static func isIndexLine(_ s: String) -> Bool {
        let t = s.trimmed
        return !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func trimTrailingBlank(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, isBlank(last) { out.removeLast() }
        return out
    }

    /// Lines collected before the next time line may end with that cue's sequence number.
    private static func dropTrailingIndex(_ lines: [String]) -> [String] {
        var out = trimTrailingBlank(lines)
        if out.count >= 2, let last = out.last, isIndexLine(last) {
            out.removeLast()
            out = trimTrailingBlank(out)
        }
        return out
    }

    static func cleanLine(_ line: String) -> String {
        var s = tagPattern.replacing(in: line, with: "")
        s = assPattern.replacing(in: s, with: "")
        if s.contains("&") {
            s = s.replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return s.trimmed
    }

    static func joinTextLines(_ lines: [String]) -> String {
        var result = ""
        for raw in lines {
            let line = cleanLine(raw)
            if line.isEmpty { continue }
            result = result.joinedFragment(line)
        }
        return result
    }

    // MARK: Speaker prefixes

    struct SpeakerCandidate {
        var id: String
        var remainder: String
        /// True for free-form names (`名字：`, `[名字]`, `名字 - `), which need corroboration.
        var generic: Bool
    }

    private static let feishuPrefix = RegexPattern(#"^\s*说话人\s*(\d+)\s*[:：]\s*"#)
    private static let englishPrefix = RegexPattern(#"^\s*speaker\s*(\d+)\s*[:：]\s*"#, caseInsensitive: true)
    private static let colonPrefix = RegexPattern(#"^\s*([^\s:：][^:：\n]{0,19}?)\s*[:：]\s*"#)
    private static let bracketPrefix = RegexPattern(#"^\s*\[([^\[\]\n]{1,20})\]\s*"#)
    private static let dashPrefix = RegexPattern(#"^\s*([^\s\-][^\-\n]{0,19}?)\s+-\s+"#)

    private static let forbiddenNameCharacters = Set("，。,.!！?？;；、…\"“”'‘’()（）《》<>/\\|=+*#@&%$^~`{}【】「」『』")

    private static func isValidName(_ name: String) -> Bool {
        let t = name.trimmed
        guard !t.isEmpty, t.count <= 20 else { return false }
        if t.contains(where: { forbiddenNameCharacters.contains($0) }) { return false }
        if t.allSatisfy({ $0.isNumber || $0 == " " }) { return false }
        return true
    }

    private static func remainder(_ text: String, after regex: RegexPattern) -> String? {
        guard let end = regex.prefixMatchEnd(in: text) else { return nil }
        return String(text[end...]).trimmed
    }

    static func detectSpeaker(in text: String) -> SpeakerCandidate? {
        if let g = feishuPrefix.firstMatch(in: text), let n = g[1], let rest = remainder(text, after: feishuPrefix) {
            return SpeakerCandidate(id: "说话人 \(Int(n) ?? 1)", remainder: rest, generic: false)
        }
        if let g = englishPrefix.firstMatch(in: text), let n = g[1], let rest = remainder(text, after: englishPrefix) {
            return SpeakerCandidate(id: "Speaker \(Int(n) ?? 1)", remainder: rest, generic: false)
        }
        if let g = bracketPrefix.firstMatch(in: text), let name = g[1], isValidName(name),
           let rest = remainder(text, after: bracketPrefix) {
            return SpeakerCandidate(id: name.trimmed, remainder: rest, generic: true)
        }
        if let g = colonPrefix.firstMatch(in: text), let name = g[1], isValidName(name),
           let rest = remainder(text, after: colonPrefix), !rest.hasPrefix("//") {
            return SpeakerCandidate(id: name.trimmed, remainder: rest, generic: true)
        }
        if let g = dashPrefix.firstMatch(in: text), let name = g[1], isValidName(name),
           let rest = remainder(text, after: dashPrefix) {
            return SpeakerCandidate(id: name.trimmed, remainder: rest, generic: true)
        }
        return nil
    }
}
