import AppKit
import ApplicationServices

enum InjectResult {
    case injected
    case copiedToClipboard
}

/// 把文本注入前台 App 光标处：写剪贴板 → 合成 ⌘V → 稍后恢复原剪贴板。
/// 需要辅助功能权限；未授权时降级为仅复制。
enum TextInjector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 触发系统的辅助功能授权引导弹窗
    static func promptForAccessibility() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func inject(_ text: String) -> InjectResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted,
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: 9, keyDown: true),  // kVK_ANSI_V
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return .copiedToClipboard  // 文本留在剪贴板，由调用方提示手动粘贴
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return .injected
    }
}
