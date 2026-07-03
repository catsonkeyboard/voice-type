import SwiftUI

@main
struct VoiceTypeApp: App {
    var body: some Scene {
        MenuBarExtra("VoiceType", systemImage: "mic") {
            Text("VoiceType 开发中").padding()
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .padding(.bottom, 8)
        }
    }
}
