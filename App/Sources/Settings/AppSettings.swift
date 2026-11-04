import Foundation
import Observation

struct GeneralSettings: Codable, Equatable {
    var skipBlankEnabled = false
    /// Minimum gap (seconds) that "跳过空白片段" jumps over.
    var skipBlankThreshold: Double = 2
    /// Estimated per-character highlight inside the current cue (§5.3).
    var perCharHighlight = true
    /// Insert "，" between Chinese cues without closing punctuation (§9.3).
    var insertComma = true
    /// Suffixes stripped from file names for titles and SRT pairing (§9.1.1).
    var filenameSuffixes: [String] = FilePairing.defaultSuffixes
    var ccEnabled = false
    var playbackRate: Float = 1
    var volume: Float = 1
    /// Left column share of the detail page (§1, ~57%).
    var detailSplit: Double = 0.57

    init() {}

    enum CodingKeys: String, CodingKey {
        case skipBlankEnabled, skipBlankThreshold, perCharHighlight, insertComma, filenameSuffixes
        case ccEnabled, playbackRate, volume, detailSplit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        skipBlankEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipBlankEnabled) ?? d.skipBlankEnabled
        skipBlankThreshold = try c.decodeIfPresent(Double.self, forKey: .skipBlankThreshold) ?? d.skipBlankThreshold
        perCharHighlight = try c.decodeIfPresent(Bool.self, forKey: .perCharHighlight) ?? d.perCharHighlight
        insertComma = try c.decodeIfPresent(Bool.self, forKey: .insertComma) ?? d.insertComma
        filenameSuffixes = try c.decodeIfPresent([String].self, forKey: .filenameSuffixes) ?? d.filenameSuffixes
        ccEnabled = try c.decodeIfPresent(Bool.self, forKey: .ccEnabled) ?? d.ccEnabled
        playbackRate = try c.decodeIfPresent(Float.self, forKey: .playbackRate) ?? d.playbackRate
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? d.volume
        detailSplit = try c.decodeIfPresent(Double.self, forKey: .detailSplit) ?? d.detailSplit
    }
}

/// Remembers §7.4 downgrades per endpoint in UserDefaults.
final class UserDefaultsCompatStore: CompatStore {
    private let key = "llm.compatFlags"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func load() -> [String: CompatFlags] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: CompatFlags].self, from: data) else { return [:] }
        return dict
    }

    func flags(for key: String) -> CompatFlags {
        lock.lock(); defer { lock.unlock() }
        return load()[key] ?? CompatFlags()
    }

    func setFlags(_ flags: CompatFlags, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        dict[key] = flags
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: self.key) }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}

/// Settings live in UserDefaults; API keys in `SecretStore`, one per provider preset.
@MainActor
@Observable
final class AppSettings {
    private static let generalKey = "settings.general"
    private static let llmKey = "settings.llm"

    private var storedGeneral: GeneralSettings
    private var storedLLM: LLMConfig
    private var storedAPIKey: String

    let compatStore = UserDefaultsCompatStore()

    init() {
        let defaults = UserDefaults.standard
        let general = defaults.data(forKey: Self.generalKey).flatMap { try? JSONDecoder().decode(GeneralSettings.self, from: $0) }
        let llm = defaults.data(forKey: Self.llmKey).flatMap { try? JSONDecoder().decode(LLMConfig.self, from: $0) }
        storedGeneral = general ?? GeneralSettings()
        let config = llm ?? LLMConfig()
        storedLLM = config
        storedAPIKey = SecretStore.read(account: config.presetID) ?? ""
    }

    var general: GeneralSettings {
        get { storedGeneral }
        set {
            guard newValue != storedGeneral else { return }
            storedGeneral = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.generalKey)
            }
        }
    }

    var llm: LLMConfig {
        get { storedLLM }
        set {
            guard newValue != storedLLM else { return }
            let presetChanged = newValue.presetID != storedLLM.presetID
            storedLLM = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.llmKey)
            }
            if presetChanged {
                storedAPIKey = SecretStore.read(account: newValue.presetID) ?? ""
            }
        }
    }

    var apiKey: String {
        get { storedAPIKey }
        set {
            guard newValue != storedAPIKey else { return }
            storedAPIKey = newValue
            SecretStore.write(newValue.trimmingCharacters(in: .whitespacesAndNewlines), account: storedLLM.presetID)
        }
    }

    var currentPreset: ProviderPreset? { ProviderPreset.preset(id: storedLLM.presetID) }

    /// Ready to call the API (local servers may run without a key).
    var isLLMReady: Bool { storedLLM.isConfigured }
}
