import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case formatUnsupported

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "没有可用的麦克风输入设备"
        case .formatUnsupported: return "麦克风音频格式不受支持"
        }
    }
}

/// AVAudioEngine 麦克风采集，tap 内实时重采样为 16kHz 单声道 Float32。
/// start/stop 需在主线程调用；采样累积在音频线程，用锁保护。
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()

    /// 音频电平回调（0~1），主线程派发，供 HUD 显示
    var onLevel: ((Float) -> Void)?
    /// 转换后的 16k chunk 实时回调（主线程派发，云端推流用）
    var onChunk: (([Float]) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let srcFormat = input.outputFormat(forBus: 0)
        guard srcFormat.sampleRate > 0, srcFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw RecorderError.formatUnsupported
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: srcFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 返回本次录音的全部 16k 采样
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = dstFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuf.frameLength > 0 else { return }

        let chunk = UnsafeBufferPointer(
            start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
        let chunkArray = Array(chunk)
        lock.lock()
        samples.append(contentsOf: chunkArray)
        lock.unlock()

        var sum: Float = 0
        for v in chunkArray { sum += v * v }
        let rms = (sum / Float(max(chunkArray.count, 1))).squareRoot()
        let level = min(1, rms * 12)
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
            self?.onChunk?(chunkArray)
        }
    }
}
