import AppKit

/// 桌宠联动（v6）的进出口：收 voicetype:// 请求，发 pet:// 回传。
///
/// 为什么自己接管 GetURL 事件：SwiftUI 没有可靠的入口——菜单栏面板的视图只在面板打开时存在；
/// 默认处理还会顺带打开一个空的「会议转写」窗口（那个窗口组按 URL 打开）。
/// 在 applicationWillFinishLaunching 里注册处理器后，App 正在运行或由这个 URL 拉起都能收到，
/// 也不会开窗口（2026-10-02 实测）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(
        _ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor
    ) {
        guard
            let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: text),
            let request = PetRequest.parse(url)
        else {
            // 只记这一行，不写 URL 的任何部分
            NSLog("VoiceType: 忽略了一个无法识别的 voicetype:// 请求")
            return
        }
        Task { @MainActor in
            AppDependencies.shared.dictation.handle(request)
        }
    }
}

extension PetCallback {
    /// 把结果回传给桌宠。不激活桌宠，不抢用户正在用的 App 的焦点。
    /// 日志里不写回传内容。
    @MainActor
    static func send(callback: URL, session: String, outcome: PetOutcome) {
        guard let url = url(callback: callback, session: session, outcome: outcome) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error {
                NSLog("VoiceType: 回传桌宠失败（%ld）", (error as NSError).code)
            }
        }
    }
}
