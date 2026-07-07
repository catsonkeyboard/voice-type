import Foundation

enum AsrEngine: String, Codable, CaseIterable {
    case local
    case dashscope

    var label: String {
        switch self {
        case .local: return "本地 SenseVoice"
        case .dashscope: return "云端 Fun-ASR-Realtime"
        }
    }
}

enum SettingsStore {
    private static let defaults = UserDefaults.standard

    static var hotwordsText: String {
        get { defaults.string(forKey: "hotwordsText") ?? "" }
        set { defaults.set(newValue, forKey: "hotwordsText") }
    }

    static var hotwords: [String] {
        hotwordsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var keyCombo: HotkeyManager.KeyCombo {
        get {
            guard let data = defaults.data(forKey: "keyCombo"),
                let combo = try? JSONDecoder().decode(HotkeyManager.KeyCombo.self, from: data)
            else { return .default }
            return combo
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "keyCombo")
        }
    }

    // MARK: - 识别引擎（v3）

    static var asrEngine: AsrEngine {
        get {
            defaults.string(forKey: "asrEngine").flatMap(AsrEngine.init(rawValue:)) ?? .local
        }
        set { defaults.set(newValue.rawValue, forKey: "asrEngine") }
    }

    static var dashScopeModel: String {
        get { defaults.string(forKey: "dashScopeModel") ?? "fun-asr-realtime" }
        set { defaults.set(newValue, forKey: "dashScopeModel") }
    }

    static var dashScopeAPIKey: String {
        get { KeychainStore.get("dashscope-api-key") ?? "" }
        set { KeychainStore.set(newValue, account: "dashscope-api-key") }
    }

    /// 把历史遗留的明文 Key 迁入 Keychain（App 启动时调用一次）
    static func migrateSecretsToKeychainIfNeeded(polishAccount: String = "polish-api-key") {
        if let legacy = defaults.string(forKey: "polishAPIKey"), !legacy.isEmpty {
            if KeychainStore.get(polishAccount) == nil {
                KeychainStore.set(legacy, account: polishAccount)
            }
            defaults.removeObject(forKey: "polishAPIKey")
        }
    }

    // MARK: - 润色（v2）

    static var polishEnabled: Bool {
        get {
            defaults.object(forKey: "polishEnabled") == nil
                ? true : defaults.bool(forKey: "polishEnabled")
        }
        set { defaults.set(newValue, forKey: "polishEnabled") }
    }

    static var polishBaseURL: String {
        get { defaults.string(forKey: "polishBaseURL") ?? "http://localhost:11434/v1" }
        set { defaults.set(newValue, forKey: "polishBaseURL") }
    }

    static var polishAPIKey: String {
        get { KeychainStore.get("polish-api-key") ?? "" }
        set { KeychainStore.set(newValue, account: "polish-api-key") }
    }

    static var polishModel: String {
        get { defaults.string(forKey: "polishModel") ?? "qwen3.5:4b-nvfp4" }
        set { defaults.set(newValue, forKey: "polishModel") }
    }

    static var polishStyle: PolishStyle {
        get {
            defaults.string(forKey: "polishStyle").flatMap(PolishStyle.init(rawValue:)) ?? .clean
        }
        set { defaults.set(newValue.rawValue, forKey: "polishStyle") }
    }

    static var polishConfig: PolishConfig {
        PolishConfig(
            enabled: polishEnabled, baseURL: polishBaseURL, apiKey: polishAPIKey,
            model: polishModel, style: polishStyle)
    }
}
