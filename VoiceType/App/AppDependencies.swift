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

    private init() {
        state = AppState()
        container = try! ModelContainer(for: TranscriptRecord.self)
        history = HistoryStore(container: container)
        asr = AsrService()
        polish = PolishService()
        dictation = DictationController(state: state, asr: asr, history: history, polish: polish)

        HotkeyManager.shared.onHotkey = { [dictation] in dictation.toggle() }
        HotkeyManager.shared.register(SettingsStore.keyCombo)
        asr.warmUp()
        if SettingsStore.polishEnabled {
            polish.warmUp()
        }
    }
}
