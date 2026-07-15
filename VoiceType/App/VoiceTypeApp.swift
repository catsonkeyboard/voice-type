import SwiftUI

@main
struct VoiceTypeApp: App {
    @State private var deps = AppDependencies.shared

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
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(deps)
        }

        WindowGroup("会议转写", id: "meeting", for: URL.self) { $url in
            if let url {
                MeetingResultView(jsonURL: url)
                    .environment(deps)
            }
        }
    }
}
