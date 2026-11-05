import Foundation

enum LLMProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case azure

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return L("OpenAI 兼容")
        case .anthropic: return "Anthropic"
        case .azure: return "Azure OpenAI"
        }
    }
}

enum OutputLanguage: String, Codable, CaseIterable, Identifiable {
    case followSource
    case simplifiedChinese
    case english
    case japanese, korean, spanish, vietnamese, french, portuguese, russian

    var id: String { rawValue }

    /// Injected verbatim into the (Chinese) user prompt, so it does not follow the UI language.
    var label: String {
        switch self {
        case .followSource: return "跟随原文"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .vietnamese: return "Tiếng Việt"
        case .french: return "Français"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        }
    }

    /// Shown in the settings picker.
    var displayName: String {
        self == .followSource ? L("跟随原文") : label
    }
}

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    /// Chinese name; `name` gives it in the UI language.
    let nameKey: String
    let protocolKind: LLMProtocol
    let baseURL: String
    let defaultModel: String

    init(id: String, name: String, protocolKind: LLMProtocol, baseURL: String, defaultModel: String) {
        self.id = id
        nameKey = name
        self.protocolKind = protocolKind
        self.baseURL = baseURL
        self.defaultModel = defaultModel
    }

    var name: String { L(nameKey) }

    static let customID = "custom"

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "openai", name: "OpenAI", protocolKind: .openAI, baseURL: "https://api.openai.com/v1", defaultModel: ""),
        ProviderPreset(id: "anthropic", name: "Anthropic", protocolKind: .anthropic, baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5-5"),
        ProviderPreset(id: "gemini", name: "Google Gemini", protocolKind: .openAI, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: ""),
        // Chinese providers, all through their OpenAI-compatible endpoints.
        ProviderPreset(id: "deepseek", name: "DeepSeek", protocolKind: .openAI, baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat"),
        ProviderPreset(id: "dashscope", name: "阿里云百炼（通义）", protocolKind: .openAI, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen-plus"),
        ProviderPreset(id: "zhipu", name: "智谱 GLM", protocolKind: .openAI, baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: ""),
        ProviderPreset(id: "moonshot", name: "月之暗面 Kimi", protocolKind: .openAI, baseURL: "https://api.moonshot.cn/v1", defaultModel: ""),
        ProviderPreset(id: "qianfan", name: "百度千帆（文心）", protocolKind: .openAI, baseURL: "https://qianfan.baidubce.com/v2", defaultModel: "ernie-4.0-turbo-128k"),
        ProviderPreset(id: "hunyuan", name: "腾讯混元", protocolKind: .openAI, baseURL: "https://tokenhub.tencentmaas.com/v1", defaultModel: "hy3-preview"),
        ProviderPreset(id: "volcengine", name: "火山方舟（豆包）", protocolKind: .openAI, baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: ""),
        ProviderPreset(id: "siliconflow", name: "硅基流动", protocolKind: .openAI, baseURL: "https://api.siliconflow.cn/v1", defaultModel: ""),
        ProviderPreset(id: "openrouter", name: "OpenRouter", protocolKind: .openAI, baseURL: "https://openrouter.ai/api/v1", defaultModel: ""),
        ProviderPreset(id: "ollama", name: "Ollama（本地）", protocolKind: .openAI, baseURL: "http://localhost:11434/v1", defaultModel: ""),
        ProviderPreset(id: "lmstudio", name: "LM Studio（本地）", protocolKind: .openAI, baseURL: "http://localhost:1234/v1", defaultModel: ""),
        ProviderPreset(id: "azure", name: "Azure OpenAI", protocolKind: .azure, baseURL: "https://{resource}.openai.azure.com", defaultModel: ""),
        ProviderPreset(id: customID, name: "自定义", protocolKind: .openAI, baseURL: "", defaultModel: ""),
    ]

    static func preset(id: String) -> ProviderPreset? { all.first { $0.id == id } }

    var isLocal: Bool { id == "ollama" || id == "lmstudio" }
}

struct HeaderPair: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var value: String
}

struct LLMConfig: Codable, Equatable {
    var presetID: String = "openai"
    var protocolKind: LLMProtocol = .openAI
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = ""
    var outputLanguage: OutputLanguage = .followSource
    /// When false, `temperature` is never sent.
    var temperatureEnabled: Bool = true
    var temperature: Double = 0.3
    var maxOutputTokens: Int = 4096
    /// Seconds.
    var timeout: Double = 180
    var maxInputChars: Int = 60_000
    var customHeaders: [HeaderPair] = []
    var azureAPIVersion: String = "2024-10-21"
    var anthropicVersion: String = "2023-06-01"

    init() {}

    var isConfigured: Bool {
        !baseURL.trimmed.isEmpty && !model.trimmed.isEmpty && !baseURL.contains("{")
    }

    /// Key for remembering per-endpoint parameter downgrades (§7.4).
    var compatKey: String {
        "\(protocolKind.rawValue)|\(baseURL.trimmed.lowercased())|\(model.trimmed)"
    }

    /// Fills protocol, base URL, model and the defaults that suit the provider.
    mutating func apply(preset: ProviderPreset) {
        presetID = preset.id
        protocolKind = preset.protocolKind
        if preset.id != ProviderPreset.customID {
            baseURL = preset.baseURL
            model = preset.defaultModel
        }
        if preset.protocolKind == .anthropic {
            // Current Claude models reject sampling parameters and think before answering,
            // and thinking tokens count toward max_tokens – give them room.
            temperatureEnabled = false
            maxOutputTokens = max(maxOutputTokens, 16_000)
        } else {
            temperatureEnabled = true
            if maxOutputTokens == 16_000 { maxOutputTokens = 4096 }
        }
    }

    enum CodingKeys: String, CodingKey {
        case presetID, protocolKind, baseURL, model, outputLanguage, temperatureEnabled, temperature
        case maxOutputTokens, timeout, maxInputChars, customHeaders, azureAPIVersion, anthropicVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMConfig()
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? d.presetID
        protocolKind = try c.decodeIfPresent(LLMProtocol.self, forKey: .protocolKind) ?? d.protocolKind
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        outputLanguage = try c.decodeIfPresent(OutputLanguage.self, forKey: .outputLanguage) ?? d.outputLanguage
        temperatureEnabled = try c.decodeIfPresent(Bool.self, forKey: .temperatureEnabled) ?? d.temperatureEnabled
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? d.maxOutputTokens
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? d.timeout
        maxInputChars = try c.decodeIfPresent(Int.self, forKey: .maxInputChars) ?? d.maxInputChars
        customHeaders = try c.decodeIfPresent([HeaderPair].self, forKey: .customHeaders) ?? d.customHeaders
        azureAPIVersion = try c.decodeIfPresent(String.self, forKey: .azureAPIVersion) ?? d.azureAPIVersion
        anthropicVersion = try c.decodeIfPresent(String.self, forKey: .anthropicVersion) ?? d.anthropicVersion
    }
}

extension LLMConfig {
    var favoriteKey: String { FavoriteModel.key(presetID: presetID, baseURL: baseURL, model: model) }

    /// What gets recorded with a summary made with this configuration.
    var summaryParameters: SummaryParameters {
        SummaryParameters(presetID: presetID,
                          providerName: ProviderPreset.preset(id: presetID)?.nameKey ?? "自定义",
                          protocolKind: protocolKind.rawValue, baseURL: baseURL.trimmed,
                          outputLanguage: outputLanguage.rawValue,
                          temperature: temperatureEnabled ? temperature : nil,
                          maxOutputTokens: maxOutputTokens, maxInputChars: maxInputChars,
                          promptVersion: Prompts.version)
    }
}

/// A starred model: the endpoint plus the model name, so a summary can be generated with it
/// without changing the settings. The API key is the one saved for its provider preset.
struct FavoriteModel: Codable, Hashable, Identifiable {
    var presetID: String
    var protocolKind: LLMProtocol
    var baseURL: String
    var model: String
    var azureAPIVersion: String
    var anthropicVersion: String
    var customHeaders: [HeaderPair]

    var id: String { Self.key(presetID: presetID, baseURL: baseURL, model: model) }

    static func key(presetID: String, baseURL: String, model: String) -> String {
        "\(presetID)|\(baseURL.trimmed.lowercased())|\(model.trimmed)"
    }

    init(config: LLMConfig, model: String? = nil) {
        presetID = config.presetID
        protocolKind = config.protocolKind
        baseURL = config.baseURL.trimmed
        self.model = (model ?? config.model).trimmed
        azureAPIVersion = config.azureAPIVersion
        anthropicVersion = config.anthropicVersion
        customHeaders = config.customHeaders
    }

    var providerName: String { ProviderPreset.preset(id: presetID)?.name ?? L("自定义") }

    /// `base` pointed at this model; output language, limits and timeout stay as set.
    func applied(to base: LLMConfig) -> LLMConfig {
        var c = base
        let wasAnthropic = c.protocolKind == .anthropic
        c.presetID = presetID
        c.protocolKind = protocolKind
        c.baseURL = baseURL
        c.model = model
        c.azureAPIVersion = azureAPIVersion
        c.anthropicVersion = anthropicVersion
        c.customHeaders = customHeaders
        if protocolKind == .anthropic && !wasAnthropic {
            c.temperatureEnabled = false
            c.maxOutputTokens = max(c.maxOutputTokens, 16_000)
        } else if protocolKind != .anthropic && wasAnthropic {
            c.temperatureEnabled = true
            if c.maxOutputTokens == 16_000 { c.maxOutputTokens = 4096 }
        }
        return c
    }
}

/// Parameters removed or renamed for one endpoint after HTTP 400s (§7.4).
struct CompatFlags: Codable, Equatable {
    var dropResponseFormat = false
    var useMaxCompletionTokens = false
    var dropTemperature = false
    var dropFallbacks = false
    /// Set when a DashScope model rejects `enable_thinking: false` (thinking-only models).
    var dropEnableThinking = false

    init() {}

    /// Flags saved by older builds lack the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dropResponseFormat = try c.decodeIfPresent(Bool.self, forKey: .dropResponseFormat) ?? false
        useMaxCompletionTokens = try c.decodeIfPresent(Bool.self, forKey: .useMaxCompletionTokens) ?? false
        dropTemperature = try c.decodeIfPresent(Bool.self, forKey: .dropTemperature) ?? false
        dropFallbacks = try c.decodeIfPresent(Bool.self, forKey: .dropFallbacks) ?? false
        dropEnableThinking = try c.decodeIfPresent(Bool.self, forKey: .dropEnableThinking) ?? false
    }
}

protocol CompatStore: AnyObject {
    func flags(for key: String) -> CompatFlags
    func setFlags(_ flags: CompatFlags, for key: String)
}

final class InMemoryCompatStore: CompatStore {
    private var storage: [String: CompatFlags] = [:]
    private let lock = NSLock()

    init() {}

    func flags(for key: String) -> CompatFlags {
        lock.lock(); defer { lock.unlock() }
        return storage[key] ?? CompatFlags()
    }

    func setFlags(_ flags: CompatFlags, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = flags
    }
}
