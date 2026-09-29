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
        // 基线必须在自身写入完成后读取：clearContents/setString 各自递增 changeCount，
        // 若在写入前取基线，"无他人改动"的判断永远为假，提前恢复分支永不生效
        let changeCountAtInject = pasteboard.changeCount

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
            restoreClipboardLater(
                pasteboard: pasteboard, saved: saved, injected: text,
                changeCountAtInject: changeCountAtInject)
        }
        return .injected
    }

    /// 恢复原剪贴板内容。相比固定延时，轮询的实际收益是：恢复前若用户已复制了
    /// 新内容（剪贴板不再是注入文本），放弃恢复，避免覆盖用户的剪贴板。
    /// 注意：⌘V 粘贴不会改变 changeCount，因此无法真正检测"粘贴已完成"——
    /// 正常路径仍是约 0.5s 后恢复；2s 上限仅防御 changeCount 变化但内容相同的边缘情况。
    /// - 50ms 一拍；剪贴板内容已不是注入文本 → 放弃恢复
    /// - 满 0.5s 且 changeCount 未变 → 恢复
    /// - 最长 2s → 恢复
    private static func restoreClipboardLater(
        pasteboard: NSPasteboard, saved: String, injected: String, changeCountAtInject: Int
    ) {
        Task { @MainActor in
            let pollInterval: TimeInterval = 0.05
            let grace: TimeInterval = 0.5
            let maxWait: TimeInterval = 2.0
            var waited: TimeInterval = 0
            while waited < maxWait {
                try? await Task.sleep(for: .seconds(pollInterval))
                waited += pollInterval
                let current = pasteboard.string(forType: .string)
                if current != injected {
                    // 剪贴板已被他人改写（多为用户复制新内容）：不覆盖，放弃恢复
                    return
                }
                if waited >= grace, pasteboard.changeCount == changeCountAtInject {
                    break  // 静默期满，粘贴已完成，安全恢复
                }
            }
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }
}
