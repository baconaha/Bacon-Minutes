import XCTest
@testable import MinutesCore

final class PromptTests: XCTestCase {
    /// Rule 11 must reach the titles too, and outrank the length limits that are counted in
    /// Chinese characters (which pushed models to translate English terms in titles).
    func testTerminologyRuleCoversTitles() {
        XCTAssertTrue(Prompts.system.contains("优先于各字段的字数要求"))
        XCTAssertTrue(Prompts.system.contains("chapters.title、key_points.title"))
        XCTAssertTrue(Prompts.system.contains("含英文术语时约 3–10 个词"))
        XCTAssertFalse(Prompts.system.contains("用出现次数更多的那种"))
        let user = Prompts.user(language: .followSource, title: "t", durationText: "1 分", speakers: ["A"], lines: ["[00:00] A：x"])
        XCTAssertTrue(user.contains("规则 11"))
        XCTAssertTrue(Prompts.merge(language: .followSource, partials: ["{}"]).contains("规则 11"))
        XCTAssertEqual(Prompts.version, 3)
    }
}
