import XCTest
@testable import MinutesCore

final class TimeFormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(TimeFormat.durationCN(207), "3 分 27 秒")
        XCTAssertEqual(TimeFormat.durationCN(5683), "1 小时 34 分 43 秒")
        XCTAssertEqual(TimeFormat.durationCN(3605), "1 小时 5 秒")
        XCTAssertEqual(TimeFormat.durationCN(0), "0 秒")
        XCTAssertEqual(TimeFormat.compactDuration(5683), "1:34:43")
    }

    func testTimestamps() {
        XCTAssertEqual(TimeFormat.timestamp(17.9, hours: false), "00:17")
        XCTAssertEqual(TimeFormat.timestamp(1025, hours: true), "00:17:05")
        XCTAssertEqual(TimeFormat.srtTimestamp(3723.004), "01:02:03,004")
        XCTAssertEqual(TimeFormat.parseTimestamp("[01:02]"), 62)
        XCTAssertEqual(TimeFormat.parseTimestamp("1:02:03"), 3723)
        XCTAssertNil(TimeFormat.parseTimestamp("abc"))
    }

    func testCreatedDate() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 13; c.hour = 16; c.minute = 0
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(TimeFormat.createdDate(date), "2026年10月13日 下午4:00")
    }
}

final class PairingTests: XCTestCase {
    func testNormalisation() {
        XCTAssertEqual(FilePairing.normalizedTitle("1793756624935_周会复盘_FeishuMinutes", suffixes: FilePairing.defaultSuffixes), "周会复盘")
        XCTAssertEqual(FilePairing.normalizedTitle("Lecture 3_Recording", suffixes: FilePairing.defaultSuffixes), "Lecture 3")
    }

    func testPairing() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let media = [dir.appendingPathComponent("1793756624935_周会.mp4"), dir.appendingPathComponent("访谈.m4a"),
                     URL(fileURLWithPath: "/tmp/y/lonely.mp4")]
        let subs = [dir.appendingPathComponent("周会_FeishuMinutes.srt"), URL(fileURLWithPath: "/tmp/y/other.srt"),
                    URL(fileURLWithPath: "/tmp/z/none.srt")]
        let r = FilePairing.pair(media: media, subtitles: subs, suffixes: FilePairing.defaultSuffixes)
        XCTAssertTrue(r.pairs.contains(FilePairing.Pair(media: media[0], subtitle: subs[0])))
        XCTAssertTrue(r.pairs.contains(FilePairing.Pair(media: media[1], subtitle: nil)))
        XCTAssertEqual(r.suggestions, [FilePairing.Suggestion(media: media[2], subtitle: subs[1])])
        XCTAssertEqual(r.unmatchedSubtitles, [subs[2]])
    }

    func testDateFromFileName() {
        let fallback = Date()
        let d = FilePairing.dateFromFileName("会议 2026-10-13_16-00", fallback: fallback)!
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 13)
        XCTAssertEqual(comps.hour, 16)
        XCTAssertNil(FilePairing.dateFromFileName("no date", fallback: fallback))
    }
}

final class SearchFoldTests: XCTestCase {
    func testWidthAndCaseInsensitive() {
        let hay = TextFold.fold("使用ＡＰＩ和api，Ａpi")
        XCTAssertEqual(TextFold.occurrences(of: TextFold.fold("API"), in: hay).count, 3)
    }
}

final class LLMTests: XCTestCase {
    func testJSONExtraction() throws {
        let text = "<think>reasoning {not json}</think>\n```json\n{\"overview\":\"本次会议讨论了预算\",\"key_points\":[{\"title\":\"预算\",\"content\":\"确定了预算\"}],\"todos\":[],\"chapters\":[{\"time\":\"00:57\",\"title\":\"开场\",\"summary\":\"介绍\"}],\"keywords\":[\"预算\"]}\n```"
        let parsed = try SummaryParser.parse(text)
        XCTAssertEqual(parsed.summary.overview, "本次会议讨论了预算")
        XCTAssertEqual(parsed.summary.chapters.first?.time, 57)
        XCTAssertEqual(parsed.summary.keyPoints.first?.title, "预算")
    }

    func testValidationSnapsAndFilters() {
        let input = SummaryInput(title: "t", duration: 300, speakerNames: ["A"],
                                 lines: ["[00:55] A：预算讨论", "[01:30] A：下一步", "[03:10] A：总结"],
                                 lineStarts: [55.8, 90.2, 190.0],
                                 foldedFullText: TextFold.fold("预算讨论\n下一步\n总结"), language: .followSource)
        var raw = RawSummary()
        raw.overview = "x"
        raw.chapters = [RawChapter(time: 190, title: "C", summary: ""),
                        RawChapter(time: 60, title: "A", summary: ""),
                        RawChapter(time: 95, title: "B", summary: ""),
                        RawChapter(time: 91, title: "B2", summary: "")]
        raw.todos = [RawTodo(content: "跟进", owner: "", time: 92)]
        raw.keywords = ["预算", "不存在的词", "预算"]
        let draft = SummaryGenerator.validate(raw, input: input)
        XCTAssertEqual(draft.chapters.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(draft.chapters.map(\.time), [55.8, 90.2, 190.0])
        XCTAssertEqual(draft.todos.first?.owner, "未指定")
        XCTAssertEqual(draft.todos.first?.time, 90.2)
        XCTAssertEqual(draft.keywords, ["预算"])
    }

    func testChunking() {
        let lines = Array(repeating: String(repeating: "字", count: 400), count: 10)
        let chunks = SummaryGenerator.chunk(lines: lines, maxChars: 1000)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertEqual(chunks.first, 0..<2)
        XCTAssertEqual(chunks.last, 8..<10)
    }

    func testDowngradeOrder() {
        var config = LLMConfig()
        config.model = "m"
        let req = LLMRequest(system: "s", user: "u", maxTokens: 10, jsonMode: true)
        var flags = CompatFlags()
        flags = LLMClient.nextFlags(after: flags, message: "Bad request", request: req, config: config)!
        XCTAssertTrue(flags.dropResponseFormat)
        flags = LLMClient.nextFlags(after: flags, message: "Bad request", request: req, config: config)!
        XCTAssertTrue(flags.useMaxCompletionTokens)
        flags = LLMClient.nextFlags(after: flags, message: "Bad request", request: req, config: config)!
        XCTAssertTrue(flags.dropTemperature)
        XCTAssertNil(LLMClient.nextFlags(after: flags, message: "Bad request", request: req, config: config))

        let hinted = LLMClient.nextFlags(after: CompatFlags(), message: "Unsupported parameter: 'temperature'",
                                         request: req, config: config)!
        XCTAssertTrue(hinted.dropTemperature)
        XCTAssertFalse(hinted.dropResponseFormat)
    }

    func testRequestShapes() throws {
        let client = LLMClient(compat: InMemoryCompatStore())
        let req = LLMRequest(system: "sys", user: "hi", maxTokens: 100, jsonMode: true)

        var openai = LLMConfig()
        openai.baseURL = "https://api.example.com/v1/"
        openai.model = "gpt"
        openai.customHeaders = [HeaderPair(key: "X-Test", value: "1")]
        let r1 = try client.buildRequest(req, config: openai, apiKey: "k", flags: CompatFlags())
        XCTAssertEqual(r1.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(r1.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(r1.value(forHTTPHeaderField: "X-Test"), "1")
        let b1 = try JSONSerialization.jsonObject(with: r1.httpBody!) as! [String: Any]
        XCTAssertNotNil(b1["response_format"])
        XCTAssertEqual(b1["max_tokens"] as? Int, 100)

        var anthropic = LLMConfig()
        anthropic.apply(preset: ProviderPreset.preset(id: "anthropic")!)
        let r2 = try client.buildRequest(req, config: anthropic, apiKey: "k", flags: CompatFlags())
        XCTAssertEqual(r2.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r2.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(r2.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let b2 = try JSONSerialization.jsonObject(with: r2.httpBody!) as! [String: Any]
        XCTAssertEqual(b2["system"] as? String, "sys")
        XCTAssertNil(b2["temperature"])

        var azure = LLMConfig()
        azure.protocolKind = .azure
        azure.baseURL = "https://res.openai.azure.com"
        azure.model = "my-deploy"
        let r3 = try client.buildRequest(req, config: azure, apiKey: "k", flags: CompatFlags())
        XCTAssertEqual(r3.url?.absoluteString, "https://res.openai.azure.com/openai/deployments/my-deploy/chat/completions?api-version=2024-10-21")
        XCTAssertEqual(r3.value(forHTTPHeaderField: "api-key"), "k")
        let b3 = try JSONSerialization.jsonObject(with: r3.httpBody!) as! [String: Any]
        XCTAssertNil(b3["model"])
    }

    func testResponseParsing() throws {
        let openai = #"{"choices":[{"message":{"content":"hi"},"finish_reason":"length"}]}"#.data(using: .utf8)!
        let r1 = try LLMClient.parseResponse(openai, protocolKind: .openAI)
        XCTAssertEqual(r1.text, "hi")
        XCTAssertTrue(r1.truncated)

        let anthropic = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"a"},{"type":"text","text":"b"}],"stop_reason":"end_turn"}"#.data(using: .utf8)!
        let r2 = try LLMClient.parseResponse(anthropic, protocolKind: .anthropic)
        XCTAssertEqual(r2.text, "ab")
        XCTAssertFalse(r2.truncated)

        let refusal = #"{"content":[],"stop_reason":"refusal","stop_details":{"category":"cyber"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try LLMClient.parseResponse(refusal, protocolKind: .anthropic)) { error in
            XCTAssertEqual(error as? LLMError, .refusal("cyber"))
        }

        let err = #"{"type":"error","error":{"type":"invalid_request_error","message":"temperature: not supported"}}"#.data(using: .utf8)!
        XCTAssertEqual(LLMClient.errorMessage(from: err), "temperature: not supported")
    }
}
