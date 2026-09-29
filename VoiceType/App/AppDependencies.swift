import Foundation
import Observation
import SwiftData

/// 组装全部服务，作为 environment 注入视图树。
@MainActor
@Observable
final class AppDependencies {
    /// 单例：App 场景重建会重复执行 @State 初始值表达式，
    /// 必须保证容器与快捷键只初始化一次
    static let shared = AppDependencies()

    let state: AppState
    let container: ModelContainer
    let history: HistoryStore
    let dictation: DictationController
    let asr: AsrService
    let polish: PolishService
    let meeting: MeetingController

    private init() {
        SettingsStore.migrateSecretsToKeychainIfNeeded()
        state = AppState()
        // 磁盘持久化失败（如 store 损坏）时回退内存容器：
        // 历史记录不可用不应导致整个听写 App 崩溃。
        // 内存容器无磁盘 I/O，仅 schema 非法才会失败（编译期已定，实际不可达）
        if let onDisk = try? ModelContainer(for: TranscriptRecord.self) {
            container = onDisk
        } else {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: TranscriptRecord.self, configurations: config)
        }
        history = HistoryStore(container: container)
        asr = AsrService()
        polish = PolishService()
        dictation = DictationController(state: state, asr: asr, history: history, polish: polish)
        meeting = MeetingController(state: state, asr: asr)

        HotkeyManager.shared.onHotkey = { [dictation] in dictation.toggle() }
        HotkeyManager.shared.register(SettingsStore.keyCombo)
        asr.warmUp()
        if SettingsStore.polishEnabled {
            polish.warmUp()
        }
    }
}
