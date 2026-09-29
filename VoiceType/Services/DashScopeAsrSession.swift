import Foundation

enum DashScopeError: LocalizedError {
    case notConfigured
    case connectFailed(String)
    case taskFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 DashScope API Key"
        case .connectFailed(let msg): return "云端连接失败：\(msg)"
        case .taskFailed(let msg): return "云端识别失败：\(msg)"
        case .timeout: return "云端识别超时"
        }
    }
}

/// Fun-ASR-Realtime WebSocket 会话（一次听写一个实例）。
/// 生命周期：start() → send(samples)... → finish() -> 终稿；任何失败由调用方回退本地。
/// 音频在 task-started 之前自动缓冲，之后按 ~100ms 帧推送。
/// 连接中断/任务失败时通过 onFailure 通知调用方（exactly-once），
/// finish() 在已终态的会话上立即抛错，不再空等超时。
final class DashScopeAsrSession: NSObject, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    /// 连接不可恢复地中断（网络断开/任务失败）。仅触发一次；
    /// 录音中途触发时调用方应立即切换本地引擎，finish() 不再可用。
    var onFailure: (@Sendable (Error) -> Void)?

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let taskId = DashScopeAsr.newTaskId()
    private var socket: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var assembler = SentenceAssembler()
    private var pending: [Float] = []
    private var started = false
    private var terminalError: Error?
    private var startedContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<String, Error>?

    private static let frameSamples = 1600  // 100ms @16kHz

    init(apiKey: String, model: String, endpoint: URL = DashScopeAsr.defaultEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    /// 建连 + run-task，等待 task-started（5 秒超时）
    func start() async throws {
        guard !apiKey.isEmpty else { throw DashScopeError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiveLoop()

        let runTask = DashScopeAsr.runTaskMessage(taskId: taskId, model: model)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            startedContinuation = cont
            lock.unlock()
            socket.send(.string(runTask)) { [weak self] error in
                if let error {
                    self?.resumeStarted(
                        .failure(DashScopeError.connectFailed(error.localizedDescription)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.resumeStarted(.failure(DashScopeError.timeout))
            }
        }
    }

    /// 追加音频；内部攒满 ~100ms 且任务已启动时发送二进制帧。
    /// 会话已终态时丢弃（调用方收到 onFailure 后应改用本地引擎）。
    func send(samples: [Float]) {
        lock.lock()
        if terminalError != nil {
            lock.unlock()
            return
        }
        pending.append(contentsOf: samples)
        var frame: [Float]?
        if started && pending.count >= Self.frameSamples {
            frame = pending
            pending = []
        }
        lock.unlock()
        if let frame {
            socket?.send(.data(DashScopeAsr.pcm16Data(from: frame))) { [weak self] error in
                // 发送失败通常意味着连接已断：标记终态并通知，
                // 后续音频不再推送（finish 时立即回退本地）
                if let error {
                    self?.failAll(DashScopeError.connectFailed(error.localizedDescription))
                }
            }
        }
    }

    /// 冲刷缓冲 + finish-task，等待 task-finished（15 秒超时），返回终稿。
    /// 会话已终态（断线/任务失败/已取消）时立即抛出原错误。
    func finish() async throws -> String {
        lock.lock()
        if let terminalError {
            lock.unlock()
            throw terminalError
        }
        let rest = pending
        pending = []
        lock.unlock()
        if !rest.isEmpty {
            socket?.send(.data(DashScopeAsr.pcm16Data(from: rest))) { _ in }
        }
        let message = DashScopeAsr.finishTaskMessage(taskId: taskId)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            finishContinuation = cont
            lock.unlock()
            socket?.send(.string(message)) { [weak self] error in
                if let error {
                    self?.resumeFinish(
                        .failure(DashScopeError.connectFailed(error.localizedDescription)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.resumeFinish(.failure(DashScopeError.timeout))
            }
        }
    }

    /// 放弃会话（回退/取消路径）
    func cancel() {
        socket?.cancel(with: .goingAway, reason: nil)
        failAll(CancellationError())
    }

    // MARK: - 私有

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failAll(DashScopeError.connectFailed(error.localizedDescription))
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(DashScopeAsr.parseEvent(text))
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ event: DashScopeAsr.ServerEvent) {
        switch event {
        case .taskStarted:
            lock.lock()
            started = true
            lock.unlock()
            resumeStarted(.success(()))
            send(samples: [])  // 触发已缓冲音频的冲刷判断
        case .resultGenerated(let sentence):
            lock.lock()
            assembler.ingest(sentence)
            let live = assembler.liveText
            lock.unlock()
            onPartial?(live)
        case .taskFinished:
            lock.lock()
            let final = assembler.finalText
            lock.unlock()
            resumeFinish(.success(final))
            socket?.cancel(with: .normalClosure, reason: nil)
        case .taskFailed(let code, let message):
            failAll(DashScopeError.taskFailed("\(code): \(message)"))
        case .unknown:
            break
        }
    }

    /// 恢复 continuation（exactly-once：取出即置 nil）
    private func resumeStarted(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = startedContinuation
        startedContinuation = nil
        lock.unlock()
        switch result {
        case .success: cont?.resume()
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func resumeFinish(_ result: Result<String, Error>) {
        lock.lock()
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()
        switch result {
        case .success(let text): cont?.resume(returning: text)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        let notify: (@Sendable (Error) -> Void)?
        lock.lock()
        // exactly-once：已终态的会话不再重复通知/恢复
        if terminalError == nil {
            terminalError = error
            notify = onFailure
        } else {
            notify = nil
        }
        lock.unlock()
        resumeStarted(.failure(error))
        resumeFinish(.failure(error))
        if let notify {
            notify(error)
        }
    }
}
