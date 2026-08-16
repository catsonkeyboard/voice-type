import Foundation

/// 会议功能编排：录制生命周期 + 处理进度 + 结果路径
@MainActor
final class MeetingController {
    let state: AppState
    private let recorder = MeetingRecorder()
    private let processor: MeetingProcessor

    init(state: AppState, asr: AsrService) {
        self.state = state
        self.processor = MeetingProcessor(asr: asr)
        recorder.onAutoStop = { [weak self] in self?.stopAndProcess() }
    }

    var isRecording: Bool {
        if case .recording = state.meeting { return true }
        return false
    }

    func startRecording() {
        state.refreshModelsReady()
        guard state.modelsReady else {
            state.meeting = .failed(
                "本地识别模型未安装（\(SettingsStore.localAsrModel.label)），请运行 "
                    + SettingsStore.localAsrModel.installCommand)
            return
        }
        guard ModelPaths.diarizationPresent else {
            state.meeting = .failed("说话人分离模型未安装，请运行 scripts/setup_diarization.sh")
            return
        }
        guard state.phase == .idle else {
            state.meeting = .failed("请先结束当前听写")
            return
        }
        Task {
            guard await AudioRecorder.requestPermission() else {
                state.meeting = .failed("麦克风未授权")
                return
            }
            do {
                try recorder.start()
                state.meeting = .recording(startedAt: .now)
            } catch {
                state.meeting = .failed(error.localizedDescription)
            }
        }
    }

    func stopAndProcess() {
        guard case .recording = state.meeting, let url = recorder.stop() else { return }
        process(url: url)
    }

    /// 文件入口共用：对任意音频文件做带说话人分离的会议转写
    func process(url: URL, numSpeakers: Int? = nil) {
        if case .processing = state.meeting { return }
        state.meeting = .processing(stage: "准备…", progress: 0)
        Task {
            do {
                let (_, jsonURL) = try await processor.process(
                    url: url, numSpeakers: numSpeakers
                ) { [weak self] stage, progress in
                    self?.state.meeting = .processing(stage: stage, progress: progress)
                }
                state.meeting = .idle
                state.meetingResultURL = jsonURL
            } catch {
                state.meeting = .failed("会议处理失败：\(error.localizedDescription)")
            }
        }
    }
}
