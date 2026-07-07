import AppKit
import Foundation

/// 听写编排：快捷键/面板触发 → 录音 → 识别 → 热词纠正 → 注入 → 历史。
@MainActor
final class DictationController {
    static let maxRecordingSeconds: TimeInterval = 300
    static let minRecordingSeconds: Double = 0.5

    let state: AppState
    let asr: AsrService
    let polish: PolishService
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private var capTimer: Timer?
    private var promptedAccessibility = false
    private var cloudSession: DashScopeAsrSession?

    init(state: AppState, asr: AsrService, history: HistoryStore, polish: PolishService) {
        self.state = state
        self.asr = asr
        self.history = history
        self.polish = polish
    }

    /// 快捷键与面板按钮共用的入口：idle→开始，recording→结束
    func toggle() {
        switch state.phase {
        case .idle, .error:
            startRecording()
        case .recording:
            Task { await finishRecording() }
        case .transcribing, .polishing:
            break  // 识别/润色中忽略触发
        }
    }

    private func startRecording() {
        let engine = SettingsStore.asrEngine
        switch engine {
        case .local:
            state.refreshModelsReady()
            guard state.modelsReady else {
                state.phase = .error(AsrError.modelMissing.localizedDescription)
                HUDController.shared.flash("模型未安装，请查看设置", state: state)
                return
            }
        case .dashscope:
            guard !SettingsStore.dashScopeAPIKey.isEmpty else {
                state.phase = .error(DashScopeError.notConfigured.localizedDescription)
                HUDController.shared.flash("请在设置 → 识别 中填写 DashScope API Key", state: state)
                return
            }
        }
        Task {
            guard await AudioRecorder.requestPermission() else {
                state.phase = .error("麦克风未授权")
                HUDController.shared.flash("麦克风未授权，请在系统设置中允许", state: state)
                return
            }
            do {
                if engine == .dashscope { setupCloudSession() }
                recorder.onLevel = { [weak self] level in
                    self?.state.micLevel = level
                }
                recorder.onChunk = { [weak self] chunk in
                    self?.cloudSession?.send(samples: chunk)
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
                cloudSession?.cancel()
                cloudSession = nil
                state.phase = .error(error.localizedDescription)
                HUDController.shared.flash(error.localizedDescription, state: state)
            }
        }
    }

    /// 并行建立云端会话；建连失败仅使本次云端不可用（finish 时走本地回退）
    private func setupCloudSession() {
        let session = DashScopeAsrSession(
            apiKey: SettingsStore.dashScopeAPIKey, model: SettingsStore.dashScopeModel)
        session.onPartial = { [weak self] text in
            Task { @MainActor in self?.state.partialText = text }
        }
        cloudSession = session
        Task { [weak self, session] in
            do {
                try await session.start()
            } catch {
                await MainActor.run {
                    // 仅当仍是当前会话时清除（避免竞态清掉下一次的会话）
                    if self?.cloudSession === session { self?.cloudSession = nil }
                }
            }
        }
    }

    private func finishRecording() async {
        guard state.phase == .recording else { return }
        capTimer?.invalidate()
        capTimer = nil
        let samples = recorder.stop()
        recorder.onChunk = nil
        let session = cloudSession
        cloudSession = nil
        state.partialText = nil

        let duration = Double(samples.count) / 16000.0
        guard duration >= Self.minRecordingSeconds else {
            session?.cancel()
            state.phase = .idle
            HUDController.shared.hide()
            return
        }
        state.phase = .transcribing
        do {
            var cloudDegraded = false
            var text: String
            if let session {
                do {
                    text = try await session.finish()
                } catch {
                    session.cancel()
                    cloudDegraded = true
                    text = try await asr.transcribe(samples: samples)
                }
            } else {
                if SettingsStore.asrEngine == .dashscope { cloudDegraded = true }
                text = try await asr.transcribe(samples: samples)
            }
            text = HotwordCorrector(hotwords: SettingsStore.hotwords).correct(text)
            guard !text.isEmpty else {
                state.phase = .idle
                HUDController.shared.hide()
                return
            }
            var rawText: String? = nil
            var polishDegraded = false
            if SettingsStore.polishEnabled, text.count >= 5 {
                state.phase = .polishing
                if let polished = await polish.polish(text) {
                    if polished != text { rawText = text }
                    text = polished
                } else {
                    polishDegraded = true
                }
            }
            history.add(
                text: text, durationSeconds: duration, source: "dictation", rawText: rawText)
            let result = TextInjector.inject(text)
            state.phase = .idle
            switch result {
            case .injected:
                if cloudDegraded {
                    HUDController.shared.flash("云端不可用，已用本地识别", state: state)
                } else if polishDegraded {
                    HUDController.shared.flash("润色不可用，已输出原文", state: state)
                } else {
                    HUDController.shared.hide()
                }
            case .copiedToClipboard:
                HUDController.shared.flash("已复制到剪贴板，请按 ⌘V 粘贴", state: state)
                // 首次降级时引导授权辅助功能，授权后即可直接注入
                if !TextInjector.isTrusted, !promptedAccessibility {
                    promptedAccessibility = true
                    TextInjector.promptForAccessibility()
                }
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
