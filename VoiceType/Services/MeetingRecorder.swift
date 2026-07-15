import AVFoundation

/// 会议长录音：chunk 实时写 wav 落盘（内存占用恒定，App 崩溃录音不丢）
@MainActor
final class MeetingRecorder {
    static let maxSeconds: Double = 3 * 3600

    private let recorder = AudioRecorder()
    private var file: AVAudioFile?
    private(set) var startedAt: Date?
    private(set) var fileURL: URL?
    /// 到达时长上限时回调（主线程）
    var onAutoStop: (() -> Void)?
    private var autoStopFired = false

    var isRecording: Bool { startedAt != nil }

    func start() throws {
        let dir = MeetingTranscript.meetingsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(formatter.string(from: .now)).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        fileURL = url
        autoStopFired = false
        recorder.onChunk = { [weak self] chunk in
            self?.append(chunk)
        }
        try recorder.start()
        startedAt = .now
    }

    private func append(_ chunk: [Float]) {
        guard let file, !chunk.isEmpty else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: chunk.count)
        }
        try? file.write(from: buffer)
        if let startedAt, Date().timeIntervalSince(startedAt) >= Self.maxSeconds, !autoStopFired {
            autoStopFired = true
            onAutoStop?()
        }
    }

    /// 返回录音文件；未在录音时返回 nil
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        _ = recorder.stop()
        recorder.onChunk = nil
        file = nil  // 释放即关闭 flush
        startedAt = nil
        let url = fileURL
        fileURL = nil
        return url
    }
}
