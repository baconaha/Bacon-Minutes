import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LLMRequest {
    var system: String
    var user: String
    var maxTokens: Int
    /// Ask for a JSON object (`response_format` on OpenAI-style endpoints).
    var jsonMode: Bool
}

struct LLMResponse {
    var text: String
    /// finish_reason == "length" / stop_reason == "max_tokens".
    var truncated: Bool
}

enum LLMError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidURL(String)
    case http(status: Int, message: String)
    case network(String)
    case timeout(Double)
    case emptyResponse
    case truncated
    case refusal(String?)
    case invalidJSON(String)
    case cancelled
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .invalidURL(let m): return m
        case .http(let status, let message): return "HTTP \(status)\(L("："))\(message)"
        case .network(let m): return L("网络错误：{0}", m)
        case .timeout(let seconds): return L("请求超时（{0} 秒）。可在 API 设置 → 高级中调大「超时」。", Int(seconds))
        case .emptyResponse: return L("模型返回了空内容")
        case .truncated: return L("输出被截断：已达到「最大输出 tokens」上限。请在 API 设置 → 高级中调大该值后重试。")
        case .refusal(let category):
            if let category, !category.isEmpty { return L("模型拒绝了该请求（类别：{0}）", category) }
            return L("模型拒绝了该请求")
        case .invalidJSON(let snippet): return L("模型输出不是合法 JSON：{0}", snippet)
        case .cancelled: return L("已取消")
        case .unsupported(let m): return m
        }
    }
}

final class LLMClient {
    let compat: CompatStore
    private let session: URLSession

    /// Claude models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    init(compat: CompatStore, session: URLSession? = nil) {
        self.compat = compat
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: Public API

    func complete(_ request: LLMRequest, config: LLMConfig, apiKey: String) async throws -> LLMResponse {
        let key = config.compatKey
        let original = compat.flags(for: key)
        var flags = original
        while true {
            if Task.isCancelled { throw LLMError.cancelled }
            let urlRequest = try buildRequest(request, config: config, apiKey: apiKey, flags: flags)
            let (data, http) = try await send(urlRequest, timeout: config.timeout)
            if (200..<300).contains(http.statusCode) {
                let response = try Self.parseResponse(data, protocolKind: config.protocolKind)
                if flags != original { compat.setFlags(flags, for: key) }
                return response
            }
            let message = Self.errorMessage(from: data)
            if http.statusCode == 400 || http.statusCode == 422,
               let next = Self.nextFlags(after: flags, message: message, request: request, config: config) {
                flags = next
                continue
            }
            throw LLMError.http(status: http.statusCode, message: message)
        }
    }

    /// Short request used by the settings "测试连接" button; returns elapsed seconds.
    func testConnection(config: LLMConfig, apiKey: String) async throws -> TimeInterval {
        let started = Date()
        _ = try await complete(LLMRequest(system: "You are a connectivity check.", user: "Reply with OK.",
                                          maxTokens: 64, jsonMode: false),
                               config: config, apiKey: apiKey)
        return Date().timeIntervalSince(started)
    }

    func listModels(config: LLMConfig, apiKey: String) async throws -> [String] {
        let base = Self.normalizedBase(config.baseURL)
        guard !base.isEmpty else { throw LLMError.notConfigured(L("请先填写 Base URL")) }
        var ids: [String] = []
        switch config.protocolKind {
        case .azure:
            throw LLMError.unsupported(L("Azure OpenAI 不支持获取模型列表，请在「模型」中填写部署名称"))
        case .openAI:
            let req = try modelsRequest(urlString: base + "/models", config: config, apiKey: apiKey)
            let data = try await fetch(req, timeout: min(config.timeout, 30))
            ids = Self.parseModelIDs(data).ids
        case .anthropic:
            let root = base.hasSuffix("/v1") ? base : base + "/v1"
            var after: String?
            for _ in 0..<10 {
                var s = root + "/models?limit=1000"
                if let after, let enc = after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    s += "&after_id=" + enc
                }
                let req = try modelsRequest(urlString: s, config: config, apiKey: apiKey)
                let data = try await fetch(req, timeout: min(config.timeout, 30))
                let page = Self.parseModelIDs(data)
                ids += page.ids
                guard page.hasMore, let last = page.lastID else { break }
                after = last
            }
        }
        var seen = Set<String>()
        return Self.textModels(ids.filter { seen.insert($0).inserted }.sorted())
    }

    /// Drops models that cannot write a summary (embeddings, speech, images, moderation …),
    /// so the picker only lists usable ones. Returns the input unchanged if nothing would be left.
    static func textModels(_ ids: [String]) -> [String] {
        let excluded = ["embed", "tts", "whisper", "transcribe", "moderation", "dall-e", "sora", "image",
                        "realtime", "audio", "deep-research", "computer-use", "davinci", "babbage", "rerank"]
        let kept = ids.filter { id in
            let lower = id.lowercased()
            return !excluded.contains { lower.contains($0) }
        }
        return kept.isEmpty ? ids : kept
    }

    // MARK: Request building

    static func normalizedBase(_ raw: String) -> String {
        var b = raw.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    static func endpoint(config: LLMConfig) throws -> URL {
        let base = normalizedBase(config.baseURL)
        guard !base.isEmpty else { throw LLMError.notConfigured(L("请先填写 Base URL")) }
        if base.contains("{") || base.contains("}") {
            throw LLMError.invalidURL(L("请把 Base URL 中的 {resource} 等占位符替换为实际值"))
        }
        let s: String
        switch config.protocolKind {
        case .openAI:
            s = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        case .anthropic:
            if base.hasSuffix("/v1/messages") {
                s = base
            } else if base.hasSuffix("/v1") {
                s = base + "/messages"
            } else {
                s = base + "/v1/messages"
            }
        case .azure:
            let deployment = config.model.trimmed
            guard !deployment.isEmpty else { throw LLMError.notConfigured(L("请在「模型」中填写 Azure 部署名称")) }
            let dep = deployment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment
            let version = config.azureAPIVersion.trimmed.isEmpty ? "2024-10-21" : config.azureAPIVersion.trimmed
            let ver = version.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? version
            s = base + "/openai/deployments/\(dep)/chat/completions?api-version=\(ver)"
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LLMError.invalidURL(L("Base URL 无效：{0}", base))
        }
        return url
    }

    static func usesFallbacks(config: LLMConfig, flags: CompatFlags) -> Bool {
        guard config.protocolKind == .anthropic, !flags.dropFallbacks else { return false }
        guard let host = URL(string: normalizedBase(config.baseURL))?.host?.lowercased(), host == "api.anthropic.com" else {
            return false
        }
        return fallbackModels.contains(config.model.trimmed)
    }

    private func applyHeaders(_ req: inout URLRequest, config: LLMConfig, apiKey: String, includeBeta: Bool) {
        let key = apiKey.trimmed
        switch config.protocolKind {
        case .openAI:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            let version = config.anthropicVersion.trimmed.isEmpty ? "2023-06-01" : config.anthropicVersion.trimmed
            req.setValue(version, forHTTPHeaderField: "anthropic-version")
            if includeBeta { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        case .azure:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "api-key") }
        }
        for h in config.customHeaders {
            let name = h.key.trimmed
            if !name.isEmpty { req.setValue(h.value, forHTTPHeaderField: name) }
        }
    }

    func buildRequest(_ request: LLMRequest, config: LLMConfig, apiKey: String, flags: CompatFlags) throws -> URLRequest {
        let url = try Self.endpoint(config: config)
        let model = config.model.trimmed
        if config.protocolKind != .azure && model.isEmpty {
            throw LLMError.notConfigured(L("请先填写模型名称"))
        }
        var body: [String: Any] = [:]
        let fallbacks = Self.usesFallbacks(config: config, flags: flags)
        switch config.protocolKind {
        case .openAI, .azure:
            if config.protocolKind == .openAI { body["model"] = model }
            body["messages"] = [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ]
            body[flags.useMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = request.maxTokens
            if request.jsonMode && !flags.dropResponseFormat {
                body["response_format"] = ["type": "json_object"]
            }
        case .anthropic:
            body["model"] = model
            body["max_tokens"] = request.maxTokens
            body["system"] = request.system
            body["messages"] = [["role": "user", "content": request.user]]
            if fallbacks { body["fallbacks"] = "default" }
        }
        if config.temperatureEnabled && !flags.dropTemperature {
            body["temperature"] = config.temperature
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = max(5, config.timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req, config: config, apiKey: apiKey, includeBeta: fallbacks)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    private func modelsRequest(urlString: String, config: LLMConfig, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL(L("Base URL 无效：{0}", urlString)) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyHeaders(&req, config: config, apiKey: apiKey, includeBeta: false)
        return req
    }

    // MARK: Downgrades (§7.4)

    enum DowngradeStep: CaseIterable {
        case responseFormat, maxCompletionTokens, temperature, fallbacks

        var keywords: [String] {
            switch self {
            case .responseFormat: return ["response_format", "json_object", "json mode"]
            case .maxCompletionTokens: return ["max_tokens", "max_completion_tokens"]
            case .temperature: return ["temperature"]
            case .fallbacks: return ["fallback", "anthropic-beta"]
            }
        }
    }

    static func nextFlags(after flags: CompatFlags, message: String, request: LLMRequest, config: LLMConfig) -> CompatFlags? {
        let openAIStyle = config.protocolKind != .anthropic
        func applicable(_ step: DowngradeStep) -> Bool {
            switch step {
            case .responseFormat: return openAIStyle && request.jsonMode && !flags.dropResponseFormat
            case .maxCompletionTokens: return openAIStyle && !flags.useMaxCompletionTokens
            case .temperature: return config.temperatureEnabled && !flags.dropTemperature
            case .fallbacks: return usesFallbacks(config: config, flags: flags)
            }
        }
        let candidates = DowngradeStep.allCases.filter(applicable)
        guard !candidates.isEmpty else { return nil }
        let lower = message.lowercased()
        let step = candidates.first { s in s.keywords.contains { lower.contains($0) } } ?? candidates[0]
        var next = flags
        switch step {
        case .responseFormat: next.dropResponseFormat = true
        case .maxCompletionTokens: next.useMaxCompletionTokens = true
        case .temperature: next.dropTemperature = true
        case .fallbacks: next.dropFallbacks = true
        }
        return next
    }

    // MARK: Response parsing

    static func parseResponse(_ data: Data, protocolKind: LLMProtocol) throws -> LLMResponse {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(decoding: data.prefix(300), as: UTF8.self)
            throw LLMError.network(L("无法解析服务端响应：{0}", raw))
        }
        if let err = obj["error"], !(err is NSNull), obj["choices"] == nil, obj["content"] == nil {
            throw LLMError.http(status: 200, message: errorText(err) ?? L("未知错误"))
        }
        switch protocolKind {
        case .openAI, .azure:
            guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
                throw LLMError.emptyResponse
            }
            let finish = first["finish_reason"] as? String
            var text = ""
            if let message = first["message"] as? [String: Any] {
                if let s = message["content"] as? String {
                    text = s
                } else if let parts = message["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined()
                }
                if text.isEmpty, let refusal = message["refusal"] as? String, !refusal.isEmpty {
                    throw LLMError.refusal(refusal)
                }
            } else if let s = first["text"] as? String {
                text = s
            }
            if finish == "content_filter" && text.isEmpty { throw LLMError.refusal("content_filter") }
            return LLMResponse(text: text, truncated: finish == "length")
        case .anthropic:
            let stop = obj["stop_reason"] as? String
            if stop == "refusal" {
                let details = obj["stop_details"] as? [String: Any]
                throw LLMError.refusal(details?["category"] as? String)
            }
            let blocks = obj["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return LLMResponse(text: text, truncated: stop == "max_tokens")
        }
    }

    private static func errorText(_ any: Any) -> String? {
        if let s = any as? String { return s }
        if let d = any as? [String: Any] {
            if let m = d["message"] as? String { return m }
            if let inner = d["error"] { return errorText(inner) }
        }
        return nil
    }

    /// Server-side message text from an error body (OpenAI, Anthropic, Gemini array form, plain text).
    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let d = obj as? [String: Any] {
                if let e = d["error"], let m = errorText(e) { return m }
                if let m = d["message"] as? String { return m }
                if let m = d["detail"] as? String { return m }
            } else if let arr = obj as? [[String: Any]], let first = arr.first {
                if let e = first["error"], let m = errorText(e) { return m }
            }
        }
        let raw = String(decoding: data.prefix(500), as: UTF8.self).trimmed
        return raw.isEmpty ? L("（服务端未返回内容）") : raw
    }

    static func parseModelIDs(_ data: Data) -> (ids: [String], hasMore: Bool, lastID: String?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], false, nil) }
        let list = (obj["data"] as? [[String: Any]]) ?? (obj["models"] as? [[String: Any]]) ?? []
        let ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        return (ids, (obj["has_more"] as? Bool) ?? false, obj["last_id"] as? String)
    }

    // MARK: Transport

    private func fetch(_ request: URLRequest, timeout: Double) async throws -> Data {
        let (data, http) = try await send(request, timeout: timeout)
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func set(_ t: URLSessionDataTask) {
            lock.lock()
            task = t
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { t.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    private func send(_ request: URLRequest, timeout: Double) async throws -> (Data, HTTPURLResponse) {
        var adjusted = request
        adjusted.timeoutInterval = max(5, timeout)
        let req = adjusted
        let box = TaskBox()
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                            cont.resume(throwing: LLMError.cancelled)
                        } else if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                            cont.resume(throwing: LLMError.timeout(timeout))
                        } else {
                            cont.resume(throwing: LLMError.network(error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        cont.resume(throwing: LLMError.network(L("无效的响应")))
                        return
                    }
                    cont.resume(returning: (data ?? Data(), http))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
