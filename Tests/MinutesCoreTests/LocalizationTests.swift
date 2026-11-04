import XCTest
@testable import MinutesCore

final class LocalizationTests: XCTestCase {
    func testBestLanguageFromPreferences() {
        XCTAssertEqual(AppLanguage.best(for: ["zh-Hant-TW"]), .zhHans)
        XCTAssertEqual(AppLanguage.best(for: ["de-DE", "ja-JP"]), .ja)
        XCTAssertEqual(AppLanguage.best(for: ["pt-BR"]), .pt)
        XCTAssertEqual(AppLanguage.best(for: ["en_US"]), .en)
        XCTAssertEqual(AppLanguage.best(for: ["de"]), .en)
        XCTAssertEqual(AppLanguage.best(for: []), .en)
    }

    func testPlaceholdersAndContextSuffix() {
        XCTAssertEqual(Localizer.fill("已选 {0} 项，{1}", [3, "好"]), "已选 3 项，好")
        XCTAssertEqual(L("{0} 个", 5), "5 个")
        // The test bundle has no tables, so lookups fall back to the key without its @@context.
        XCTAssertEqual(L("播放@@settings", in: .en), "播放")
        XCTAssertEqual(L("请把 Base URL 中的 {resource} 等占位符替换为实际值", in: .fr),
                       "请把 Base URL 中的 {resource} 等占位符替换为实际值")
    }

    func testDurationsPerLanguage() {
        XCTAssertEqual(TimeFormat.duration(5683, language: .en), "1h 34m 43s")
        XCTAssertEqual(TimeFormat.duration(5683, language: .ja), "1時間34分43秒")
        XCTAssertEqual(TimeFormat.duration(207, language: .ko), "3분 27초")
        XCTAssertEqual(TimeFormat.duration(3605, language: .fr), "1 h 5 s")
        XCTAssertEqual(TimeFormat.duration(0, language: .ru), "0 с")
        XCTAssertEqual(TimeFormat.roughDuration(43_500), "12 小时 5 分")
        XCTAssertEqual(TimeFormat.roughDuration(207), "3 分 27 秒")
    }
}
