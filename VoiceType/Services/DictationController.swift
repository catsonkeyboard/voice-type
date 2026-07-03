import AppKit
import Foundation

/// 听写编排：快捷键/面板触发 → 录音 → 识别 → 热词纠正 → 注入 → 历史。
@MainActor
final class DictationController {
    static let maxRecordingSeconds: TimeInterval = 300
    static let minRecordingSeconds: Double = 0.5

    let state: AppState
    let asr: AsrService
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private var capTimer: Timer?

    init(state: AppState, asr: AsrService, history: HistoryStore) {
        self.state = state
        self.asr = asr
        self.history = history
    }

    /// 快捷键与面板按钮共用的入口：idle→开始，recording→结束
    func toggle() {
        switch state.phase {
        case .idle, .error:
            startRecording()
        case .recording:
            Task { await finishRecording() }
        case .transcribing:
            break  // 识别中忽略触发
        }
    }

    private func startRecording() {
        state.refreshModelsReady()
        guard state.modelsReady else {
            state.phase = .error(AsrError.modelMissing.localizedDescription)
            HUDController.shared.flash("模型未安装，请查看设置", state: state)
            return
        }
        Task {
            guard await AudioRecorder.requestPermission() else {
                state.phase = .error("麦克风未授权")
                HUDController.shared.flash("麦克风未授权，请在系统设置中允许", state: state)
                return
            }
            do {
                recorder.onLevel = { [weak self] level in
                    self?.state.micLevel = level
                }
                try recorder.start()
                state.phase = .recording
                HUDController.shared.show(state: state)
                capTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.maxRecordingSeconds, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in await self?.finishRecording() }
                }
            } catch {
                state.phase = .error(error.localizedDescription)
                HUDController.shared.flash(error.localizedDescription, state: state)
            }
        }
    }

    private func finishRecording() async {
        guard state.phase == .recording else { return }
        capTimer?.invalidate()
        capTimer = nil
        let samples = recorder.stop()
        let duration = Double(samples.count) / 16000.0
        guard duration >= Self.minRecordingSeconds else {
            state.phase = .idle
            HUDController.shared.hide()
            return
        }
        state.phase = .transcribing
        do {
            var text = try await asr.transcribe(samples: samples)
            text = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
            guard !text.isEmpty else {
                state.phase = .idle
                HUDController.shared.hide()
                return
            }
            history.add(text: text, durationSeconds: duration, source: "dictation")
            let result = TextInjector.inject(text)
            state.phase = .idle
            switch result {
            case .injected:
                HUDController.shared.hide()
            case .copiedToClipboard:
                HUDController.shared.flash("已复制到剪贴板，请按 ⌘V 粘贴", state: state)
            }
        } catch {
            state.phase = .error(error.localizedDescription)
            HUDController.shared.flash("识别失败：\(error.localizedDescription)", state: state)
        }
    }

    /// 面板文件转写入口
    func transcribeFile(url: URL) {
        if case .running = state.fileJob { return }
        state.refreshModelsReady()
        guard state.modelsReady else {
            state.fileJob = .failed(AsrError.modelMissing.localizedDescription)
            return
        }
        state.fileJob = .running(progress: 0)
        Task {
            do {
                let text = try await asr.transcribeFile(url: url) { [weak self] progress in
                    Task { @MainActor in
                        self?.state.fileJob = .running(progress: progress)
                    }
                }
                if text.isEmpty {
                    state.fileJob = .failed("未识别到语音内容")
                } else {
                    let corrected = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
                    history.add(text: corrected, durationSeconds: 0, source: "file")
                    state.fileJob = .done(text: corrected)
                }
            } catch {
                state.fileJob = .failed(error.localizedDescription)
            }
        }
    }
}
