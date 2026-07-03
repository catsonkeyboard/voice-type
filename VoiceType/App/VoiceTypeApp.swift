import SwiftUI

@main
struct VoiceTypeApp: App {
    @State private var deps = AppDependencies()

    private var menuBarIcon: String {
        switch deps.state.phase {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .polishing: return "sparkles"
        case .error: return "mic.slash"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(deps)
                .modelContainer(deps.container)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(deps)
        }
    }
}
