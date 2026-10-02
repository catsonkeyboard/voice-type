import AppKit
import Foundation

/// 听写编排：快捷键/面板/桌宠触发 → 录音 → 识别 → 热词纠正 → 注入或回传 → 历史。
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
    /// 云端会话在录音中途断开：本次结束直接走本地识别并提示
    private var cloudDroppedMidway = false
    /// 当前这次听写的去向；结束或取消时复位为 .cursor
    private var target: DictationTarget = .cursor
    /// 录音正在启动（等麦克风授权）。这期间不再接受新的开始
    private var starting = false
    /// 启动期间桌宠已经要求结束或取消：启动完成后立刻执行
    private var pendingEnd: PendingEnd?

    init(state: AppState, asr: AsrService, history: HistoryStore, polish: PolishService) {
        self.state = state
        self.asr = asr
        self.history = history
        self.polish = polish
    }

    /// 快捷键与面板按钮共用的入口：idle→开始，recording→结束
    func toggle() {
        if case .recording = state.meeting {
            HUDController.shared.flash("会议录音进行中，听写不可用", state: state)
            return
        }
        // 录音正在启动：这一下不能再开一次
        guard !starting else { return }
        switch state.phase {
        case .idle, .error:
            startRecording(target: .cursor)
        case .recording:
            Task { await finishRecording() }
        case .transcribing, .polishing:
            break  // 识别/润色中忽略触发
        }
    }

    /// 桌宠通过 voicetype:// 发来的请求（v6）
    func handle(_ request: PetRequest) {
        var idle = false
        if !starting {
            switch state.phase {
            case .idle, .error: idle = true
            default: break
            }
        }
        var meetingRecording = false
        if case .recording = state.meeting { meetingRecording = true }
        let action = request.action(
            idle: idle, recording: starting || state.phase == .recording,
            meetingRecording: meetingRecording, target: target)
        switch action {
        case .start(let session, let callback):
            startRecording(target: .pet(session: session, callback: callback))
        case .finish:
            if starting {
                pendingEnd = PendingEnd.merge(pendingEnd, .finish)
            } else {
                Task { await finishRecording() }
            }
        case .cancel:
            if starting {
                pendingEnd = PendingEnd.merge(pendingEnd, .cancel)
            } else {
                cancelRecording()
            }
        case .refuse(let session, let callback, let reason):
            PetCallback.send(callback: callback, session: session, outcome: .failure(reason))
        case .ignore:
            break
        }
    }

    private func startRecording(target: DictationTarget) {
        self.target = target
        let engine = SettingsStore.asrEngine
        switch engine {
        case .local:
            state.refreshModelsReady()
            guard state.modelsReady else {
                state.phase = .error(AsrError.modelMissing.localizedDescription)
                HUDController.shared.flash("模型未安装，请查看设置", state: state)
                failStart(.notReady)
                return
            }
        case .dashscope:
            guard !SettingsStore.dashScopeAPIKey.isEmpty else {
                state.phase = .error(DashScopeError.notConfigured.localizedDescription)
                HUDController.shared.flash("请在设置 → 识别 中填写 DashScope API Key", state: state)
                failStart(.notReady)
                return
            }
        }
        starting = true
        pendingEnd = nil
        Task {
            guard await AudioRecorder.requestPermission() else {
                starting = false
                state.phase = .error("麦克风未授权")
                HUDController.shared.flash("麦克风未授权，请在系统设置中允许", state: state)
                failStart(.micDenied)
                return
            }
            do {
                cloudDroppedMidway = false
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
                starting = false
                cloudSession?.cancel()
                cloudSession = nil
                state.phase = .error(error.localizedDescription)
                HUDController.shared.flash(error.localizedDescription, state: state)
                failStart(.failed)
                return
            }
            starting = false
            // 启动期间桌宠已经要求结束或取消：现在执行
            let early = pendingEnd
            pendingEnd = nil
            switch early {
            case .finish:
                await finishRecording()
            case .cancel:
                cancelRecording()
            case nil:
                break
            }
        }
    }

    /// 录音没能开始：若由桌宠发起，把原因回传；去向复位。
    /// 启动期间桌宠已经取消了这次会话时不回传：取消从不回传。
    private func failStart(_ reason: PetFailure) {
        if pendingEnd != .cancel { reply(target, .failure(reason)) }
        target = .cursor
        pendingEnd = nil
    }

    /// 只有桌宠发起的听写才回传
    private func reply(_ target: DictationTarget, _ outcome: PetOutcome) {
        guard case .pet(let session, let callback) = target else { return }
        PetCallback.send(callback: callback, session: session, outcome: outcome)
    }

    /// 并行建立云端会话；建连失败仅使本次云端不可用（finish 时走本地回退）。
    /// 录音中途连接中断时立即切换为本地模式（音频全程在本地累积，无内容丢失）。
    private func setupCloudSession() {
        let session = DashScopeAsrSession(
            apiKey: SettingsStore.dashScopeAPIKey, model: SettingsStore.dashScopeModel)
        session.onPartial = { [weak self] text in
            Task { @MainActor in self?.state.partialText = text }
        }
        session.onFailure = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.cloudSession === session else { return }
                // 仅当仍是当前会话时清除（避免竞态清掉下一次的会话）
                self.cloudSession = nil
                self.state.partialText = nil
                self.cloudDroppedMidway = true
                // 本地音频完整保留，继续录音；结束时直接走本地识别
                HUDController.shared.flash("云端连接中断，将使用本地识别", state: self.state)
            }
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
        // 无论当前处于什么状态，先解除定时器，避免非 recording 路径残留强引用
        capTimer?.invalidate()
        capTimer = nil
        guard state.phase == .recording else { return }
        // 去向在这里取走：识别期间开始的下一次听写不受影响
        let target = self.target
        self.target = .cursor
        let samples = recorder.stop()
        recorder.onChunk = nil
        let session = cloudSession
        cloudSession = nil
        let droppedMidway = cloudDroppedMidway
        cloudDroppedMidway = false
        state.partialText = nil

        let duration = Double(samples.count) / 16000.0
        guard duration >= Self.minRecordingSeconds else {
            session?.cancel()
            state.phase = .idle
            HUDController.shared.hide()
            reply(target, .failure(.empty))
            return
        }
        DebugAudioDump.write(samples: samples)
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
            // 热词纠正在后台执行（拼音转换+编辑距离开销与文本长度成正比）
            let hotwords = SettingsStore.hotwords
            text = await Task.detached(priority: .userInitiated) {
                HotwordCorrector(hotwords: hotwords).correct(text)
            }.value
            guard !text.isEmpty else {
                state.phase = .idle
                HUDController.shared.hide()
                reply(target, .failure(.empty))
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
                text: text, durationSeconds: duration,
                source: target == .cursor ? "dictation" : "pet", rawText: rawText)
            // 中途断开已在断线时提示过，这里不重复
            let degraded: String? =
                cloudDegraded && !droppedMidway
                ? "云端不可用，已用本地识别" : (polishDegraded ? "润色不可用，已输出原文" : nil)
            if case .pet = target {
                // 桌宠发起：回传文字，不写剪贴板、不模拟 ⌘V、不引导辅助功能授权
                state.phase = .idle
                reply(target, .text(text))
                showDegraded(degraded)
                return
            }
            let result = TextInjector.inject(text)
            state.phase = .idle
            switch result {
            case .injected:
                showDegraded(degraded)
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
            reply(target, .failure(.failed))
        }
    }

    /// 降级提示显示一下；没有降级就收起 HUD
    private func showDegraded(_ message: String?) {
        if let message {
            HUDController.shared.flash(message, state: state)
        } else {
            HUDController.shared.hide()
        }
    }

    /// 丢弃当前录音：不识别、不回传（桌宠取消了这次说话）
    private func cancelRecording() {
        capTimer?.invalidate()
        capTimer = nil
        guard state.phase == .recording else { return }
        _ = recorder.stop()
        recorder.onChunk = nil
        cloudSession?.cancel()
        cloudSession = nil
        cloudDroppedMidway = false
        state.partialText = nil
        target = .cursor
        state.phase = .idle
        HUDController.shared.hide()
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
                    let hotwords = SettingsStore.hotwords
                    let corrected = await Task.detached(priority: .userInitiated) {
                        HotwordCorrector(hotwords: hotwords).correct(text)
                    }.value
                    history.add(text: corrected, durationSeconds: 0, source: "file")
                    state.fileJob = .done(text: corrected)
                }
            } catch {
                state.fileJob = .failed(error.localizedDescription)
            }
        }
    }
}
