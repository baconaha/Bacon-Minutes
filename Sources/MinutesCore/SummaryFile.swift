import Foundation

/// `.baconsummary`: one summary plus what it was made from (recording, subtitles, model and
/// request parameters). Plain JSON, identical on macOS and Windows, so files move between both.
struct SummaryFile: Codable {
    static let formatID = "bacon-minutes-summary"
    static let fileExtension = "baconsummary"
    static let currentVersion = 1

    /// The minute the summary was generated for.
    struct Source: Codable, Hashable {
        var title: String
        var createdAt: Date?
        var duration: Double
        var mediaFileName: String
        var mediaSize: Int64?
        var srtFileName: String?
        var cueCount: Int
        var speakerCount: Int
        /// `Transcript.cuesHash`: cue text and timing only.
        var cuesHash: String?
        /// `Transcript.contentHash`: also covers speaker names.
        var transcriptHash: String?
    }

    struct Generation: Codable, Hashable {
        var model: String
        var generatedAt: Date
        var parameters: SummaryParameters?
    }

    struct Content: Codable, Hashable {
        var overview: String
        var keyPoints: [KeyPoint]
        var todos: [TodoItem]
        var chapters: [Chapter]
        var keywords: [String]
    }

    var format: String
    var version: Int
    var exportedAt: Date
    /// Producing app, e.g. "Bacon Minutes 1.0 (macOS)".
    var app: String
    var source: Source
    var generation: Generation
    var summary: Content

    static func make(summary s: Summary, minute: Minute, transcript: Transcript?, app: String,
                     exportedAt: Date = Date()) -> SummaryFile {
        let source = Source(title: minute.title, createdAt: minute.createdAt, duration: minute.duration,
                            mediaFileName: minute.mediaFileName, mediaSize: minute.mediaSize,
                            srtFileName: transcript?.srtFileName ?? minute.srtFileName,
                            cueCount: transcript?.cues.count ?? minute.cueCount,
                            speakerCount: transcript?.speakers.count ?? minute.speakerCount,
                            cuesHash: s.cuesHash ?? transcript?.cuesHash,
                            transcriptHash: s.transcriptHash.isEmpty ? nil : s.transcriptHash)
        return SummaryFile(format: formatID, version: currentVersion, exportedAt: exportedAt, app: app, source: source,
                           generation: Generation(model: s.model, generatedAt: s.generatedAt, parameters: s.parameters),
                           summary: Content(overview: s.overview, keyPoints: s.keyPoints, todos: s.todos,
                                            chapters: s.chapters, keywords: s.keywords))
    }

    /// A new summary version for the minute this file is imported into.
    func makeSummary() -> Summary {
        Summary(draft: SummaryDraft(overview: summary.overview, keyPoints: summary.keyPoints, todos: summary.todos,
                                    chapters: summary.chapters, keywords: summary.keywords),
                model: generation.model, generatedAt: generation.generatedAt,
                transcriptHash: source.transcriptHash ?? "", cuesHash: source.cuesHash,
                parameters: generation.parameters)
    }

    // MARK: Coding

    enum FileError: LocalizedError, Equatable {
        case invalid
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalid: return L("不是有效的纪要文件")
            case .newerVersion(let v): return L("纪要文件版本较新（{0}），请先更新应用", v)
            }
        }
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// Accepts ISO 8601 dates with or without fractional seconds (the Windows app writes them).
    static func decode(_ data: Data) throws -> SummaryFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date \(text)")
        }
        guard let file = try? d.decode(SummaryFile.self, from: data), file.format == formatID else {
            throw FileError.invalid
        }
        if file.version > currentVersion { throw FileError.newerVersion(file.version) }
        return file
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    // MARK: Matching

    /// Ways the file's source differs from the minute it is being imported into.
    enum Mismatch: Equatable {
        /// The minute has no subtitles to compare with.
        case noTranscript
        /// Cue text or timing differ.
        case transcript
        case media(file: String, current: String)
        case duration(file: Double, current: Double)

        var text: String {
            switch self {
            case .noTranscript:
                return L("当前妙记还没有字幕，无法核对内容")
            case .transcript:
                return L("字幕内容不同")
            case .media(let file, let current):
                return L("媒体文件不同：纪要来自「{0}」，当前是「{1}」", file, current)
            case .duration(let file, let current):
                return L("时长不同：纪要来自 {0} 的录制，当前为 {1}", TimeFormat.duration(file), TimeFormat.duration(current))
            }
        }
    }

    func mismatches(minute: Minute, transcript: Transcript?) -> [Mismatch] {
        var out: [Mismatch] = []
        if let hash = source.cuesHash {
            if let transcript {
                if transcript.cuesHash != hash { out.append(.transcript) }
            } else {
                out.append(.noTranscript)
            }
        }
        let fileName = source.mediaFileName.trimmed
        if !fileName.isEmpty, fileName.lowercased() != minute.mediaFileName.trimmed.lowercased() {
            out.append(.media(file: fileName, current: minute.mediaFileName))
        }
        if source.duration > 0, minute.duration > 0, abs(source.duration - minute.duration) > 2 {
            out.append(.duration(file: source.duration, current: minute.duration))
        }
        return out
    }
}
