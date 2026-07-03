import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 点击后捕获下一次带修饰键的按键，作为新的全局快捷键。
struct KeyComboRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyManager.KeyCombo

    func makeNSView(context: Context) -> KeyCaptureButton {
        let button = KeyCaptureButton(frame: .zero)
        button.title = combo.display
        button.onCapture = { combo = $0 }
        return button
    }

    func updateNSView(_ nsView: KeyCaptureButton, context: Context) {
        if !nsView.isCapturing {
            nsView.title = combo.display
        }
        nsView.onCapture = { combo = $0 }
    }
}

final class KeyCaptureButton: NSButton {
    var onCapture: ((HotkeyManager.KeyCombo) -> Void)?
    private(set) var isCapturing = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        title = "按下新快捷键…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil  // 吞掉事件
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            endCapture(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return  // 必须带修饰键，继续等待
        }
        let combo = HotkeyManager.KeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: HotkeyManager.carbonModifiers(from: flags),
            display: Self.display(flags: flags, event: event))
        endCapture(combo)
    }

    private func endCapture(_ combo: HotkeyManager.KeyCombo?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isCapturing = false
        if let combo {
            title = combo.display
            onCapture?(combo)
        }
    }

    private static func display(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        return parts + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            return event.charactersIgnoringModifiers?.uppercased()
                ?? "键码\(event.keyCode)"
        }
    }
}
