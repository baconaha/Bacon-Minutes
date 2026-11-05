import Foundation

// MARK: - Transcript

/// One subtitle entry. `id` equals the cue's index in the start-sorted cue array.
struct Cue: Codable, Identifiable, Hashable {
    let id: Int
    var start: Double
    var end: Double
    var text: String
    var speakerID: String

    var duration: Double { max(0, end - start) }
}

/// Consecutive cues of one speaker merged for display (§9.3).
struct Paragraph: Identifiable, Hashable {
    let id: Int
    let speakerID: String
    let cueIDs: [Int]
    var start: Double
    /// Largest `end` among the paragraph's cues.
    var end: Double
}

struct Speaker: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var colorHex: String
}

struct Transcript: Codable {
    var cues: [Cue]
    var speakers: [Speaker]
    var srtFileName: String
    var importedAt: Date

    func speaker(_ id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    func speakerName(_ id: String) -> String {
        speaker(id)?.name ?? id
    }

    /// Stable fingerprint of everything the summary depends on (cue text, timing and speaker names).
    var contentHash: String {
        var names: [String: String] = [:]
        for s in speakers { names[s.id] = s.name }
        var hasher = FNV1a()
        for cue in cues {
            hasher.combine(names[cue.speakerID] ?? cue.speakerID)
            hasher.combine("|")
            hasher.combine(String(Int((cue.start * 1000).rounded())))
            hasher.combine("|")
            hasher.combine(String(Int((cue.end * 1000).rounded())))
            hasher.combine("|")
            hasher.combine(cue.text)
            hasher.combine("\n")
        }
        return hasher.hexDigest
    }

    /// Fingerprint of the cues alone (text and timing, not speaker names), used to tell whether
    /// an exported summary belongs to this recording even after speakers were renamed.
    var cuesHash: String {
        var hasher = FNV1a()
        for cue in cues {
            hasher.combine(String(Int((cue.start * 1000).rounded())))
            hasher.combine("|")
            hasher.combine(String(Int((cue.end * 1000).rounded())))
            hasher.combine("|")
            hasher.combine(cue.text)
            hasher.combine("\n")
        }
        return hasher.hexDigest
    }
}

enum SpeakerPalette {
    static let colors = ["#3370FF", "#F5A623", "#2EA121", "#7B61FF", "#F54A45", "#14A9D9", "#FF8800", "#D136D1"]

    static func color(at index: Int) -> String {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

// MARK: - Summary

struct KeyPoint: Codable, Hashable {
    var title: String
    var content: String
}

struct TodoItem: Codable, Hashable {
    var content: String
    var owner: String
    var time: Double
}

struct Chapter: Codable, Hashable {
    var time: Double
    var title: String
    var summary: String
}

/// Validated model output, before it is stamped with model name / hash.
struct SummaryDraft: Hashable {
    var overview: String
    var keyPoints: [KeyPoint]
    var todos: [TodoItem]
    var chapters: [Chapter]
    var keywords: [String]
}

/// How a summary was made: provider, endpoint and the request parameters.
struct SummaryParameters: Codable, Hashable {
    var presetID: String
    var providerName: String
    var protocolKind: String
    var baseURL: String
    var outputLanguage: String
    /// Nil when temperature was not sent.
    var temperature: Double?
    var maxOutputTokens: Int
    var maxInputChars: Int
    var promptVersion: Int

    init(presetID: String, providerName: String, protocolKind: String, baseURL: String, outputLanguage: String,
         temperature: Double?, maxOutputTokens: Int, maxInputChars: Int, promptVersion: Int) {
        self.presetID = presetID
        self.providerName = providerName
        self.protocolKind = protocolKind
        self.baseURL = baseURL
        self.outputLanguage = outputLanguage
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.maxInputChars = maxInputChars
        self.promptVersion = promptVersion
    }

    enum CodingKeys: String, CodingKey {
        case presetID, providerName, protocolKind, baseURL, outputLanguage, temperature
        case maxOutputTokens, maxInputChars, promptVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? ""
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        protocolKind = try c.decodeIfPresent(String.self, forKey: .protocolKind) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        outputLanguage = try c.decodeIfPresent(String.self, forKey: .outputLanguage) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        maxInputChars = try c.decodeIfPresent(Int.self, forKey: .maxInputChars) ?? 0
        promptVersion = try c.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 0
    }
}

/// One generated summary. A minute can keep several (different models, regenerations).
struct Summary: Codable, Identifiable {
    var id: UUID
    var overview: String
    var keyPoints: [KeyPoint]
    var todos: [TodoItem]
    var chapters: [Chapter]
    var keywords: [String]
    var model: String
    var generatedAt: Date
    var transcriptHash: String
    /// `Transcript.cuesHash` at generation time.
    var cuesHash: String?
    var parameters: SummaryParameters?

    init(id: UUID = UUID(), draft: SummaryDraft, model: String, generatedAt: Date, transcriptHash: String,
         cuesHash: String? = nil, parameters: SummaryParameters? = nil) {
        self.id = id
        overview = draft.overview
        keyPoints = draft.keyPoints
        todos = draft.todos
        chapters = draft.chapters
        keywords = draft.keywords
        self.model = model
        self.generatedAt = generatedAt
        self.transcriptHash = transcriptHash
        self.cuesHash = cuesHash
        self.parameters = parameters
    }

    var draft: SummaryDraft {
        SummaryDraft(overview: overview, keyPoints: keyPoints, todos: todos, chapters: chapters, keywords: keywords)
    }

    enum CodingKeys: String, CodingKey {
        case id, overview, keyPoints, todos, chapters, keywords, model, generatedAt, transcriptHash, cuesHash, parameters
    }

    /// Summaries saved before versions existed have no id; they get one when read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        keyPoints = try c.decodeIfPresent([KeyPoint].self, forKey: .keyPoints) ?? []
        todos = try c.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        transcriptHash = try c.decodeIfPresent(String.self, forKey: .transcriptHash) ?? ""
        cuesHash = try c.decodeIfPresent(String.self, forKey: .cuesHash)
        parameters = try c.decodeIfPresent(SummaryParameters.self, forKey: .parameters)
    }

    /// Chapter whose range contains `t` (last chapter starting at or before `t`).
    func chapter(at t: Double) -> Chapter? {
        var found: Chapter?
        for c in chapters {
            if c.time <= t + 0.001 { found = c } else { break }
        }
        return found
    }
}

// MARK: - Minute (one library item)

/// Where a minute's media lives: a copy inside the app, or a link to the user's file.
enum MediaStorage: String, Codable {
    /// Bookmark / path to the original file, which may move or go offline.
    case linked
    /// Copied into the minute's folder in the app's library.
    case imported
}

struct Minute: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var lastOpenedAt: Date?
    var duration: Double
    var mediaBookmark: Data
    /// Last known absolute path of the media file (for display and as a fallback).
    var mediaPath: String
    var mediaFileName: String
    var isAudioOnly: Bool
    var srtBookmark: Data?
    var srtFileName: String?
    var cueCount: Int
    var speakerCount: Int
    var hasSummary: Bool
    /// Non-nil means the item is in the trash.
    var deletedAt: Date?
    /// Resume position for the next open.
    var lastPlaybackPosition: Double
    /// User folder this minute is filed under (it is still listed under "全部").
    var folderID: UUID?
    /// Size of the media file in bytes, when known.
    var mediaSize: Int64?
    var storage: MediaStorage
    /// Summary version shown when the minute opens.
    var activeSummaryID: UUID?
    /// Right-hand tab shown when the minute was last left ("summary" / "transcript").
    var lastTab: String?

    var hasTranscript: Bool { srtFileName != nil }

    init(id: UUID = UUID(), title: String, createdAt: Date, duration: Double, mediaBookmark: Data,
         mediaPath: String, mediaFileName: String, isAudioOnly: Bool) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastOpenedAt = nil
        self.duration = duration
        self.mediaBookmark = mediaBookmark
        self.mediaPath = mediaPath
        self.mediaFileName = mediaFileName
        self.isAudioOnly = isAudioOnly
        self.srtBookmark = nil
        self.srtFileName = nil
        self.cueCount = 0
        self.speakerCount = 0
        self.hasSummary = false
        self.deletedAt = nil
        self.lastPlaybackPosition = 0
        self.folderID = nil
        self.mediaSize = nil
        self.storage = .linked
        self.activeSummaryID = nil
        self.lastTab = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, lastOpenedAt, duration, mediaBookmark, mediaPath, mediaFileName, isAudioOnly
        case srtBookmark, srtFileName, cueCount, speakerCount, hasSummary, deletedAt, lastPlaybackPosition
        case folderID, mediaSize, storage, activeSummaryID, lastTab
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        mediaBookmark = try c.decodeIfPresent(Data.self, forKey: .mediaBookmark) ?? Data()
        mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath) ?? ""
        mediaFileName = try c.decodeIfPresent(String.self, forKey: .mediaFileName) ?? ""
        isAudioOnly = try c.decodeIfPresent(Bool.self, forKey: .isAudioOnly) ?? false
        srtBookmark = try c.decodeIfPresent(Data.self, forKey: .srtBookmark)
        srtFileName = try c.decodeIfPresent(String.self, forKey: .srtFileName)
        cueCount = try c.decodeIfPresent(Int.self, forKey: .cueCount) ?? 0
        speakerCount = try c.decodeIfPresent(Int.self, forKey: .speakerCount) ?? 0
        hasSummary = try c.decodeIfPresent(Bool.self, forKey: .hasSummary) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        lastPlaybackPosition = try c.decodeIfPresent(Double.self, forKey: .lastPlaybackPosition) ?? 0
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        mediaSize = try c.decodeIfPresent(Int64.self, forKey: .mediaSize)
        storage = try c.decodeIfPresent(MediaStorage.self, forKey: .storage) ?? .linked
        activeSummaryID = try c.decodeIfPresent(UUID.self, forKey: .activeSummaryID)
        lastTab = try c.decodeIfPresent(String.self, forKey: .lastTab)
    }
}

/// A user folder in the sidebar. Minutes reference it by id.
struct Folder: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - Stable hash

/// 64-bit FNV-1a. Swift's `Hasher` is seeded per process, so it cannot be persisted.
struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
    }

    var hexDigest: String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
