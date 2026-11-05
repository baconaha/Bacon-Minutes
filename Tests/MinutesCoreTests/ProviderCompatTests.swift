import XCTest
@testable import MinutesCore

final class ProviderCompatTests: XCTestCase {
    private func body(_ r: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
    }

    func testChinesePresets() {
        let ids = ProviderPreset.all.map(\.id)
        for id in ["deepseek", "dashscope", "zhipu", "moonshot", "qianfan", "hunyuan", "volcengine"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(ProviderPreset.preset(id: "qianfan")?.baseURL, "https://qianfan.baidubce.com/v2")
        XCTAssertEqual(ProviderPreset.preset(id: "hunyuan")?.protocolKind, .openAI)
    }

    func testDashScopeAsksForNoThinkingAndCanDropIt() throws {
        var config = LLMConfig()
        config.apply(preset: ProviderPreset.preset(id: "dashscope")!)
        let client = LLMClient(compat: InMemoryCompatStore())
        let req = LLMRequest(system: "s", user: "u", maxTokens: 10, jsonMode: true)
        let b = try body(client.buildRequest(req, config: config, apiKey: "k", flags: CompatFlags()))
        XCTAssertEqual(b["enable_thinking"] as? Bool, false)

        // Only dropped when the error names it; a generic 400 tries the other parameters first.
        let named = LLMClient.nextFlags(after: CompatFlags(), message: "parameter.enable_thinking must be set to true",
                                        request: req, config: config)!
        XCTAssertTrue(named.dropEnableThinking)
        let generic = LLMClient.nextFlags(after: CompatFlags(), message: "Bad request", request: req, config: config)!
        XCTAssertFalse(generic.dropEnableThinking)
        let dropped = try body(client.buildRequest(req, config: config, apiKey: "k", flags: named))
        XCTAssertNil(dropped["enable_thinking"])

        var other = LLMConfig()
        other.apply(preset: ProviderPreset.preset(id: "deepseek")!)
        XCTAssertNil(try body(client.buildRequest(req, config: other, apiKey: "k", flags: CompatFlags()))["enable_thinking"])
    }

    func testErrorBodiesFromChineseProviders() {
        XCTAssertEqual(LLMClient.errorMessage(from: Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8)),
                       "Open api daily request limit reached")
        XCTAssertEqual(LLMClient.errorMessage(from: Data(#"{"error":{"code":"invalid_model","message":"model not found"}}"#.utf8)),
                       "model not found")
    }

    func testOldSavedFlagsStillDecode() throws {
        let old = Data(#"{"dropResponseFormat":true,"useMaxCompletionTokens":false,"dropTemperature":true,"dropFallbacks":false}"#.utf8)
        let flags = try JSONDecoder().decode(CompatFlags.self, from: old)
        XCTAssertTrue(flags.dropResponseFormat)
        XCTAssertFalse(flags.dropEnableThinking)
    }
}
