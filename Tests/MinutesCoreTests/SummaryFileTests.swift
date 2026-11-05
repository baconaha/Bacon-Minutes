import XCTest
@testable import MinutesCore

final class SummaryFileTests: XCTestCase {
    private func transcript(speakerName: String = "说话人 1") -> Transcript {
        Transcript(cues: [Cue(id: 0, start: 0, end: 1.5, text: "大家好", speakerID: "s1"),
                          Cue(id: 1, start: 1.5, end: 3.25, text: "Hello world", speakerID: "s1")],
                   speakers: [Speaker(id: "s1", name: speakerName, colorHex: "#3370FF")],
                   srtFileName: "lecture.srt", importedAt: Date(timeIntervalSince1970: 0))
    }

    private func minute(fileName: String = "lecture.mp4", duration: Double = 3600) -> Minute {
        var m = Minute(title: "Lecture 1", createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: duration,
                       mediaBookmark: Data(), mediaPath: "/tmp/\(fileName)", mediaFileName: fileName, isAudioOnly: false)
        m.cueCount = 2
        m.speakerCount = 1
        return m
    }

    private func summary(for t: Transcript) -> Summary {
        Summary(draft: SummaryDraft(overview: "本节课讲解了 kinematics。", keyPoints: [KeyPoint(title: "SUVAT", content: "…")],
                                    todos: [TodoItem(content: "完成习题", owner: "未指定", time: 12)],
                                    chapters: [Chapter(time: 0, title: "Intro", summary: "…")], keywords: ["velocity"]),
                model: "deepseek-chat", generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
                transcriptHash: t.contentHash, cuesHash: t.cuesHash,
                parameters: LLMConfig().summaryParameters)
    }

    /// Same values as the Windows test suite, so both apps agree on what "same subtitles" means.
    func testHashesMatchWindows() {
        XCTAssertEqual(transcript().cuesHash, "98cf95ed8bca9311")
        XCTAssertEqual(transcript().contentHash, "cd1242d8775c3df1")
        // Renaming a speaker changes the content hash but not the cues hash.
        XCTAssertEqual(transcript(speakerName: "Ms Lee").cuesHash, "98cf95ed8bca9311")
        XCTAssertNotEqual(transcript(speakerName: "Ms Lee").contentHash, "cd1242d8775c3df1")
    }

    func testRoundTripAndMatch() throws {
        let t = transcript()
        let m = minute()
        let file = SummaryFile.make(summary: summary(for: t), minute: m, transcript: t, app: "Bacon Minutes 1.0 (macOS)",
                                    exportedAt: Date(timeIntervalSince1970: 1_760_000_000))
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\" : \"bacon-minutes-summary\""))
        let back = try SummaryFile.decode(data)
        XCTAssertEqual(back.source, file.source)
        XCTAssertEqual(back.summary, file.summary)
        XCTAssertEqual(back.generation.model, "deepseek-chat")
        XCTAssertEqual(back.generation.parameters?.promptVersion, Prompts.version)
        XCTAssertEqual(back.mismatches(minute: m, transcript: t), [])

        let s = back.makeSummary()
        XCTAssertEqual(s.model, "deepseek-chat")
        XCTAssertEqual(s.cuesHash, t.cuesHash)
        XCTAssertEqual(s.chapters.first?.title, "Intro")
    }

    func testMismatches() throws {
        let t = transcript()
        let file = SummaryFile.make(summary: summary(for: t), minute: minute(), transcript: t, app: "test")
        // Renamed speakers still match.
        XCTAssertEqual(file.mismatches(minute: minute(), transcript: transcript(speakerName: "Ms Lee")), [])

        var other = t
        other.cues[1].text = "Goodbye"
        let problems = file.mismatches(minute: minute(fileName: "other.mkv", duration: 100), transcript: other)
        XCTAssertEqual(problems, [.transcript, .media(file: "lecture.mp4", current: "other.mkv"),
                                  .duration(file: 3600, current: 100)])
        XCTAssertEqual(file.mismatches(minute: minute(), transcript: nil), [.noTranscript])
        // File names compare case-insensitively; durations within 2 s are the same recording.
        XCTAssertEqual(file.mismatches(minute: minute(fileName: "LECTURE.MP4", duration: 3601.5), transcript: t), [])
    }

    /// A file written by the Windows app: ISO dates with milliseconds, no parameters.
    func testReadsWindowsFile() throws {
        let json = """
        {"format":"bacon-minutes-summary","version":1,"exportedAt":"2026-11-05T08:30:00.123Z",
         "app":"Bacon Minutes 1.0.0 (Windows)",
         "source":{"title":"Lecture 1","createdAt":"2026-11-01T02:00:00.000Z","duration":3600,"mediaFileName":"lecture.mp4",
                   "mediaSize":123456789,"srtFileName":"lecture.srt","cueCount":2,"speakerCount":1,
                   "cuesHash":"98cf95ed8bca9311","transcriptHash":"cd1242d8775c3df1"},
         "generation":{"model":"qwen-plus","generatedAt":"2026-11-05T08:00:00.500Z"},
         "summary":{"overview":"o","keyPoints":[{"title":"t","content":"c"}],"todos":[],
                    "chapters":[{"time":0,"title":"Intro","summary":"s"}],"keywords":["k"]}}
        """
        let file = try SummaryFile.decode(Data(json.utf8))
        XCTAssertEqual(file.generation.model, "qwen-plus")
        XCTAssertNil(file.generation.parameters)
        XCTAssertEqual(file.source.mediaSize, 123_456_789)
        XCTAssertEqual(file.mismatches(minute: minute(), transcript: transcript()), [])
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try SummaryFile.decode(Data("{\"format\":\"something-else\",\"version\":1}".utf8))) { error in
            XCTAssertEqual(error as? SummaryFile.FileError, .invalid)
        }
        XCTAssertThrowsError(try SummaryFile.decode(Data("not json".utf8)))
    }

    /// Summaries saved before versions existed still load, each with an id.
    func testLegacySummaryDecodes() throws {
        let json = """
        {"overview":"o","keyPoints":[],"todos":[],"chapters":[],"keywords":[],"model":"gpt-4o",
         "generatedAt":"2026-01-01T00:00:00Z","transcriptHash":"abc","feedback":1}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode(Summary.self, from: Data(json.utf8))
        XCTAssertEqual(s.model, "gpt-4o")
        XCTAssertNil(s.cuesHash)
        XCTAssertNil(s.parameters)
        // Minutes from before storage modes are linked.
        let m = try d.decode(Minute.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"x"}"#.utf8))
        XCTAssertEqual(m.storage, .linked)
        XCTAssertNil(m.activeSummaryID)
    }

    func testFavoriteModelAppliesEndpoint() {
        var base = LLMConfig()
        base.apply(preset: ProviderPreset.preset(id: "deepseek")!)
        base.outputLanguage = .english
        base.maxInputChars = 30_000
        var claude = LLMConfig()
        claude.apply(preset: ProviderPreset.preset(id: "anthropic")!)
        let fav = FavoriteModel(config: claude, model: "claude-opus-5-5")
        XCTAssertEqual(fav.id, "anthropic|https://api.anthropic.com|claude-opus-5-5")

        let c = fav.applied(to: base)
        XCTAssertEqual(c.presetID, "anthropic")
        XCTAssertEqual(c.protocolKind, .anthropic)
        XCTAssertEqual(c.model, "claude-opus-5-5")
        XCTAssertFalse(c.temperatureEnabled)
        XCTAssertGreaterThanOrEqual(c.maxOutputTokens, 16_000)
        // Settings that are not about the endpoint stay.
        XCTAssertEqual(c.outputLanguage, .english)
        XCTAssertEqual(c.maxInputChars, 30_000)

        let back = FavoriteModel(config: base, model: "deepseek-chat").applied(to: c)
        XCTAssertTrue(back.temperatureEnabled)
        XCTAssertEqual(back.maxOutputTokens, 4096)
        XCTAssertEqual(back.baseURL, "https://api.deepseek.com/v1")
    }

    func testUnsupportedFormats() {
        XCTAssertTrue(MediaTypes.isUnsupported(URL(fileURLWithPath: "/x/movie.MKV")))
        XCTAssertTrue(MediaTypes.isUnsupported(URL(fileURLWithPath: "/x/subs.ass")))
        XCTAssertFalse(MediaTypes.isUnsupported(URL(fileURLWithPath: "/x/movie.mp4")))
        XCTAssertTrue(MediaTypes.isSummaryFile(URL(fileURLWithPath: "/x/a.baconsummary")))
    }
}
