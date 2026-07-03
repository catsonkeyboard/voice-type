import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    enum FileJob: Equatable {
        case idle
        case running(progress: Double)
        case done(text: String)
        case failed(String)
    }

    var phase: Phase = .idle
    var micLevel: Float = 0
    /// HUD 上的一次性提示（如"已复制到剪贴板"），显示后由 HUDController 清除
    var hudMessage: String?
    var fileJob: FileJob = .idle
    var modelsReady: Bool = ModelPaths.allPresent

    func refreshModelsReady() {
        modelsReady = ModelPaths.allPresent
    }
}
