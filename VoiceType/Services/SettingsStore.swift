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
}
