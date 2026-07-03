import Foundation

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
        get { defaults.string(forKey: "polishAPIKey") ?? "" }
        set { defaults.set(newValue, forKey: "polishAPIKey") }
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
