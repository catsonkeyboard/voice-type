import AVFoundation

/// 调试辅助：保留最近一次听写实际送入 ASR 的音频（16k mono wav），
/// 用于区分"采集链路问题"与"模型识别问题"。仅保留最后一次，体积极小。
enum DebugAudioDump {
    static var lastDictationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/debug/last-dictation.wav")
    }

    static func write(samples: [Float]) {
        let url = lastDictationURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            samples.count > 0
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            return
        }
        try? file.write(from: buffer)
    }
}
