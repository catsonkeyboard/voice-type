import AppKit
import Carbon.HIToolbox

/// Carbon 全局快捷键。App 生命周期内单例，切换组合键时先注销再注册。
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct KeyCombo: Codable, Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32
        var display: String

        static let `default` = KeyCombo(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(optionKey),
            display: "⌥Space")
    }

    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register(_ combo: KeyCombo) {
        unregister()
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5654_5950), id: 1)  // 'VTYP'
        RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
    }

    /// Cocoa 修饰键 → Carbon 修饰键
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
