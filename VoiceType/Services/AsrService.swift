import Foundation

enum AsrError: LocalizedError {
    case modelMissing
    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "识别模型未安装，请在项目目录运行 scripts/export_model.sh"
        }
    }
}

enum ModelPaths {
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/models", isDirectory: true)
    }
    static var asrModel: URL { modelsDir.appendingPathComponent("model.int8.onnx") }
    static var tokens: URL { modelsDir.appendingPathComponent("tokens.txt") }
    static var vadModel: URL { modelsDir.appendingPathComponent("silero_vad.onnx") }
    static var segmentationModel: URL { modelsDir.appendingPathComponent("segmentation.onnx") }
    static var speakerEmbeddingModel: URL {
        modelsDir.appendingPathComponent("speaker-embedding.onnx")
    }
    static var diarizationPresent: Bool {
        [segmentationModel, speakerEmbeddingModel].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
    static var allPresent: Bool {
        [asrModel, tokens, vadModel].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

/// SenseVoice 离线识别服务。推理在专用串行队列执行，模型常驻内存。
final class AsrService: @unchecked Sendable {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let queue = DispatchQueue(label: "com.catsonkeyboard.voicetype.asr", qos: .userInitiated)

    /// 预热：后台加载模型（App 启动时调用）
    func warmUp() {
        queue.async { _ = try? self.loadedRecognizer() }
    }

    private func loadedRecognizer() throws -> SherpaOnnxOfflineRecognizer {
        if let recognizer { return recognizer }
        guard ModelPaths.allPresent else { throw AsrError.modelMissing }
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: ModelPaths.asrModel.path,
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: ModelPaths.tokens.path,
            numThreads: 4,
            senseVoice: senseVoice
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        let r = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = r
        return r
    }

    /// 单段音频转写（16kHz 单声道）
    func transcribe(samples: [Float], sampleRate: Int = 16000) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try self.loadedRecognizer()
                    let text = r.decode(samples: samples, sampleRate: sampleRate).text
                    cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 文件转写：解码 → silero VAD 分段 → 逐段识别，段间换行
    func transcribeFile(
        url: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try self.loadedRecognizer()
                    let silero = sherpaOnnxSileroVadModelConfig(
                        model: ModelPaths.vadModel.path,
                        threshold: 0.5,
                        minSilenceDuration: 0.5,
                        minSpeechDuration: 0.25,
                        windowSize: 512,
                        maxSpeechDuration: 20
                    )
                    var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)
                    let vad = SherpaOnnxVoiceActivityDetectorWrapper(
                        config: &vadConfig, buffer_size_in_seconds: 120)

                    var pieces: [String] = []
                    func drainSegments() {
                        while !vad.isEmpty() {
                            let seg = vad.front()
                            let text = r.decode(samples: seg.samples).text
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { pieces.append(text) }
                            vad.pop()
                        }
                    }

                    let window = 512
                    var i = 0
                    while i < samples.count {
                        let end = min(i + window, samples.count)
                        vad.acceptWaveform(samples: Array(samples[i..<end]))
                        drainSegments()
                        i = end
                        onProgress(Double(i) / Double(max(samples.count, 1)))
                    }
                    vad.flush()
                    drainSegments()
                    cont.resume(returning: pieces.joined(separator: "\n"))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
