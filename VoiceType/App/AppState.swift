import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
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
    /// 云端识别的实时中间结果（仅云端引擎录音阶段非空）
    var partialText: String?
    /// HUD 上的一次性提示（如"已复制到剪贴板"），显示后由 HUDController 清除
    var hudMessage: String?
    var fileJob: FileJob = .idle
    var modelsReady: Bool = ModelPaths.allPresent

    // MARK: - 会议（v4）

    enum MeetingPhase: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing(stage: String, progress: Double)
        case failed(String)
    }

    var meeting: MeetingPhase = .idle
    /// 最近一次会议稿 JSON 路径（结果窗口入口）
    var meetingResultURL: URL?

    func refreshModelsReady() {
        modelsReady = ModelPaths.allPresent
    }
}
