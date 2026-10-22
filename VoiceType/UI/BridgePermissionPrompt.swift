import AppKit

/// 第三方应用第一次请求 VoiceType 听写时的授权弹窗。
/// 这是联动里唯一会抢焦点的地方：只在某个回调地址第一次出现时弹一次，之后按记住的选择处理。
@MainActor
enum BridgePermissionPrompt {
    /// 回调地址对应的应用（能打开这个回调的应用）；没有应用能接收时返回 nil
    static func appURL(for callback: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: callback)
    }

    /// 回调地址对应应用的显示名；解析不到时回退为回调的 scheme
    static func appName(for callback: URL) -> String {
        guard let app = appURL(for: callback) else { return callback.scheme ?? callback.absoluteString }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// 弹窗询问是否允许。返回 true 允许、false 拒绝；没有应用能接收这个回调时返回 nil（不弹窗）
    static func ask(callback: URL) -> Bool? {
        guard let app = appURL(for: callback) else { return nil }
        let name = appName(for: callback)
        let alert = NSAlert()
        alert.messageText = "「\(name)」请求使用 VoiceType 听写"
        alert.informativeText = """
            允许后，「\(name)」可以让 VoiceType 开始录音，并接收识别出的文字。\
            录音时屏幕上会显示录音提示。

            回调地址：\(callback.absoluteString)

            之后可在 设置 → 通用 → 第三方应用 中撤销。
            """
        alert.icon = NSWorkspace.shared.icon(forFile: app.path)
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "拒绝")
        // 菜单栏应用没有前台窗口：不先激活，弹窗会落在其他窗口后面
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
