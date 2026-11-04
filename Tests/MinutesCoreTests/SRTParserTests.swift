import XCTest
@testable import MinutesCore

final class SRTParserTests: XCTestCase {
    func testFeishuFormatWithSpeakersOverlapAndShortCues() throws {
        let srt = """
        1
        00:00:55,120 --> 00:00:57,300
        说话人 1: 大家好，我们开始吧

        2
        00:00:57,000 --> 00:00:58,000
        说话人 2：好

        3
        00:00:58,000 --> 00:00:58,040
        说话人2:嗯

        5
        00:01:00,000 --> 00:01:03,500
        说话人 1: 第一件事
        是预算

        """
        let result = try SRTParser.parse(string: srt)
        XCTAssertEqual(result.cues.count, 4)
        XCTAssertEqual(result.cues.map(\.speakerID), ["说话人 1", "说话人 2", "说话人 2", "说话人 1"])
        XCTAssertEqual(result.cues[0].text, "大家好，我们开始吧")
        XCTAssertEqual(result.cues[1].text, "好")
        XCTAssertEqual(result.cues[2].text, "嗯")
        XCTAssertEqual(result.cues[3].text, "第一件事是预算")
        XCTAssertEqual(result.cues[0].start, 55.12, accuracy: 0.0001)
        XCTAssertEqual(result.cues[1].start, 57.0, accuracy: 0.0001) // overlaps cue 0, kept as is
        XCTAssertEqual(result.cues[2].duration, 0.04, accuracy: 0.0001)
        XCTAssertEqual(result.speakers.map(\.id), ["说话人 1", "说话人 2"])
        XCTAssertEqual(Set(result.cues.map(\.id)), Set(0..<4))
    }

    func testCRLFBOMTagsDotMillisecondsAndMissingIndexes() throws {
        let srt = "\u{FEFF}00:00:01.500 --> 00:00:02.000 X1:10 Y1:20\r\n<i>Hello</i>\r\nworld {\\an8}\r\n\r\n\r\n00:00:03,000 --> 00:00:04,000\r\nSpeaker 2: <font color=\"red\">Bye</font>\r\n"
        let result = try SRTParser.parse(string: srt)
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].text, "Hello world")
        XCTAssertEqual(result.cues[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(result.cues[0].speakerID, "说话人 1")
        XCTAssertEqual(result.cues[1].speakerID, "Speaker 2")
        XCTAssertEqual(result.cues[1].text, "Bye")
    }

    func testOutOfOrderCuesAreSortedByStart() throws {
        let srt = """
        2
        00:00:10,000 --> 00:00:11,000
        B

        1
        00:00:01,000 --> 00:00:02,000
        A
        """
        let result = try SRTParser.parse(string: srt)
        XCTAssertEqual(result.cues.map(\.text), ["A", "B"])
        XCTAssertEqual(result.cues.map(\.id), [0, 1])
    }

    func testGenericNamesNeedTwoOccurrences() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        张三：你好

        2
        00:00:02,000 --> 00:00:03,000
        李四：你好啊

        3
        00:00:03,000 --> 00:00:04,000
        张三：今天开会

        4
        00:00:04,000 --> 00:00:05,000
        注意：这不是名字
        """
        let result = try SRTParser.parse(string: srt)
        XCTAssertEqual(result.cues[0].speakerID, "张三")
        XCTAssertEqual(result.cues[0].text, "你好")
        // 李四 and 注意 occur once only: treated as text with the fallback speaker.
        XCTAssertEqual(result.cues[1].speakerID, SRTParser.fallbackSpeakerID)
        XCTAssertEqual(result.cues[1].text, "李四：你好啊")
        XCTAssertEqual(result.cues[3].text, "注意：这不是名字")
    }

    func testTimeLikePrefixIsNotASpeaker() {
        XCTAssertNil(SRTParser.detectSpeaker(in: "10:30 开会"))
        XCTAssertNil(SRTParser.detectSpeaker(in: "https://example.com"))
        XCTAssertEqual(SRTParser.detectSpeaker(in: "[主持人] 欢迎")?.id, "主持人")
    }

    func testUTF16Decoding() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n说话人 1: 测试\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let result = try SRTParser.parse(data: data)
        XCTAssertEqual(result.cues.first?.text, "测试")
    }

    #if canImport(Darwin)
    func testGB18030Decoding() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n说话人 1: 中文编码\n"
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = text.data(using: String.Encoding(rawValue: gb))!
        let result = try SRTParser.parse(data: data)
        XCTAssertEqual(result.cues.first?.text, "中文编码")
    }
    #endif

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try SRTParser.parse(string: "hello\nworld"))
    }
}

final class ParagraphTests: XCTestCase {
    private func cue(_ id: Int, _ s: Double, _ e: Double, _ text: String, _ sp: String) -> Cue {
        Cue(id: id, start: s, end: e, text: text, speakerID: sp)
    }

    func testMergingRules() {
        let cues = [
            cue(0, 0, 2, "我们先看", "A"),
            cue(1, 2.5, 4, "第一部分", "A"),      // same speaker, gap 0.5 → merge
            cue(2, 4.2, 5, "好", "B"),           // speaker change → new paragraph
            cue(3, 5.1, 6, "OK，对", "A"),
            cue(4, 9, 10, "接下来", "A"),          // gap 3s → new paragraph
        ]
        let ps = ParagraphBuilder.build(cues: cues)
        XCTAssertEqual(ps.map(\.cueIDs), [[0, 1], [2], [3], [4]])
        XCTAssertEqual(ps[0].start, 0)
        XCTAssertEqual(ParagraphBuilder.text(of: ps[0], cues: cues, insertComma: true), "我们先看，第一部分")
        XCTAssertEqual(ParagraphBuilder.text(of: ps[0], cues: cues, insertComma: false), "我们先看第一部分")
    }

    func testGapUsesRunningMaxEnd() {
        let cues = [
            cue(0, 0, 10, "长句", "A"),
            cue(1, 1, 2, "插入", "A"),
            cue(2, 11, 12, "继续", "A"),  // 11 - max(10, 2) = 1 < 2 → merge
        ]
        XCTAssertEqual(ParagraphBuilder.build(cues: cues).count, 1)
    }

    func testLengthLimit() {
        let long = String(repeating: "字", count: 260)
        let cues = [cue(0, 0, 1, long, "A"), cue(1, 1.1, 2, "后续", "A")]
        XCTAssertEqual(ParagraphBuilder.build(cues: cues).count, 2)
    }

    func testEnglishJoinsWithSpace() {
        XCTAssertEqual(ParagraphBuilder.separator(previous: "Hello", next: "world", insertComma: true), " ")
        XCTAssertEqual(ParagraphBuilder.separator(previous: "你好。", next: "我们", insertComma: true), "")
    }
}

final class TimelineTests: XCTestCase {
    private let cues = [
        Cue(id: 0, start: 55, end: 60, text: "a", speakerID: "A"),
        Cue(id: 1, start: 58, end: 70, text: "b", speakerID: "B"),
        Cue(id: 2, start: 61, end: 62, text: "c", speakerID: "A"),
        Cue(id: 3, start: 80, end: 85, text: "d", speakerID: "A"),
    ]

    func testActiveCue() {
        let tl = CueTimeline(cues: cues)
        XCTAssertNil(tl.activeCue(at: 10))
        XCTAssertEqual(tl.activeCue(at: 56), 0)
        XCTAssertEqual(tl.activeCue(at: 59), 1)
        XCTAssertEqual(tl.activeCue(at: 61.5), 2)
        XCTAssertEqual(tl.activeCue(at: 65), 1)   // cue 2 ended, cue 1 still covers
        XCTAssertNil(tl.activeCue(at: 75))
    }

    func testSkipTargets() {
        let tl = CueTimeline(cues: cues)
        XCTAssertEqual(tl.skipTarget(at: 0, threshold: 2), 55)       // leading gap
        XCTAssertNil(tl.skipTarget(at: 65, threshold: 2))            // covered by overlapping cue 1
        XCTAssertEqual(tl.skipTarget(at: 71, threshold: 2), 80)
        XCTAssertNil(tl.skipTarget(at: 71, threshold: 20))           // gap of 10s below threshold
        XCTAssertNil(tl.skipTarget(at: 90, threshold: 2))            // after last cue
    }
}
