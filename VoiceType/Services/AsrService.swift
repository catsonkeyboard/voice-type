import Foundation

enum AsrError: LocalizedError {
    case modelMissing
    case vadMissing

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "本地识别模型未安装（\(SettingsStore.localAsrModel.label)），请在项目目录运行 "
                + SettingsStore.localAsrModel.installCommand
        case .vadMissing:
            return "VAD 模型未安装，请运行 ./scripts/export_model.sh 或 ./scripts/download_models.sh"
        }
    }
}

enum ModelPaths {
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/models", isDirectory: true)
    }

    // MARK: - SenseVoice（历史布局，位于 models/ 根）

    static var asrModel: URL { modelsDir.appendingPathComponent("model.int8.onnx") }
    static var tokens: URL { modelsDir.appendingPathComponent("tokens.txt") }

    // MARK: - Fun-ASR-Nano-2512（models/funasr-nano/）

    static var funasrDir: URL {
        modelsDir.appendingPathComponent("funasr-nano", isDirectory: true)
    }
    static var funasrEncoder: URL {
        funasrDir.appendingPathComponent("encoder_adaptor.int8.onnx")
    }
    static var funasrLLM: URL { funasrDir.appendingPathComponent("llm.int8.onnx") }
    static var funasrEmbedding: URL { funasrDir.appendingPathComponent("embedding.int8.onnx") }
    /// tokenizer 目录（vocab.json / merges.txt / tokenizer.json）
    static var funasrTokenizer: URL {
        funasrDir.appendingPathComponent("Qwen3-0.6B", isDirectory: true)
    }

    // MARK: - Qwen3-ASR-0.6B（models/qwen3-asr/）

    static var qwen3Dir: URL {
        modelsDir.appendingPathComponent("qwen3-asr", isDirectory: true)
    }
    static var qwen3ConvFrontend: URL { qwen3Dir.appendingPathComponent("conv_frontend.onnx") }
    static var qwen3Encoder: URL { qwen3Dir.appendingPathComponent("encoder.int8.onnx") }
    static var qwen3Decoder: URL { qwen3Dir.appendingPathComponent("decoder.int8.onnx") }
    /// tokenizer 目录（vocab.json / merges.txt / tokenizer_config.json，无 tokenizer.json）
    static var qwen3Tokenizer: URL {
        qwen3Dir.appendingPathComponent("tokenizer", isDirectory: true)
    }

    // MARK: - 公共组件

    static var vadModel: URL { modelsDir.appendingPathComponent("silero_vad.onnx") }
    static var segmentationModel: URL { modelsDir.appendingPathComponent("segmentation.onnx") }
    static var speakerEmbeddingModel: URL {
        modelsDir.appendingPathComponent("speaker-embedding.onnx")
    }

    static var vadPresent: Bool {
        FileManager.default.fileExists(atPath: vadModel.path)
    }

    static var diarizationPresent: Bool {
        [segmentationModel, speakerEmbeddingModel].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// 指定档位的模型文件是否全部就位
    static func isPresent(_ model: LocalAsrModel) -> Bool {
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }
        switch model {
        case .senseVoice:
            return exists(asrModel) && exists(tokens)
        case .funasrNano:
            return [funasrEncoder, funasrLLM, funasrEmbedding].allSatisfy(exists)
                && ["vocab.json", "merges.txt", "tokenizer.json"].allSatisfy {
                    exists(funasrTokenizer.appendingPathComponent($0))
                }
        case .qwen3Asr:
            return [qwen3ConvFrontend, qwen3Encoder, qwen3Decoder].allSatisfy(exists)
                && ["vocab.json", "merges.txt", "tokenizer_config.json"].allSatisfy {
                    exists(qwen3Tokenizer.appendingPathComponent($0))
                }
        }
    }

    /// 当前选择的本地模型是否就绪
    static var allPresent: Bool { isPresent(SettingsStore.localAsrModel) }
}

/// 离线识别服务（sherpa-onnx）：SenseVoiceSmall / Fun-ASR-Nano-2512 / Qwen3-ASR-0.6B。
/// 推理在专用串行队列执行，模型常驻内存；切换档位后调用 reload() 重建。
final class AsrService: @unchecked Sendable {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var loadedModel: LocalAsrModel?
    private let queue = DispatchQueue(label: "com.catsonkeyboard.voicetype.asr", qos: .userInitiated)

    /// LLM 型模型存在 max_total_len（≈512 token ≈ 20s 音频）截断上限，
    /// 超过该时长的单次转写先经 VAD 分段再逐段识别。
    private static let llmMaxDirectSeconds: Double = 20

    private static func isLLM(_ model: LocalAsrModel) -> Bool {
        switch model {
        case .funasrNano, .qwen3Asr: return true
        case .senseVoice: return false
        }
    }

    /// 预热：后台加载当前档位模型（App 启动时调用）
    func warmUp() {
        queue.async { _ = try? self.loadedRecognizer() }
    }

    /// 切换档位后调用：释放旧模型并立即按新档位重载
    func reload() {
        queue.async {
            self.recognizer = nil
            self.loadedModel = nil
            _ = try? self.loadedRecognizer()
        }
    }

    private func loadedRecognizer() throws -> SherpaOnnxOfflineRecognizer {
        let model = SettingsStore.localAsrModel
        if let recognizer, loadedModel == model { return recognizer }
        guard ModelPaths.isPresent(model) else { throw AsrError.modelMissing }


        let modelConfig: SherpaOnnxOfflineModelConfig
        switch model {
        case .senseVoice:
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: ModelPaths.tokens.path,
                numThreads: 4,
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                    model: ModelPaths.asrModel.path,
                    language: "auto",
                    useInverseTextNormalization: true
                ))
        case .funasrNano:
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: 4,
                funasrNano: sherpaOnnxOfflineFunASRNanoModelConfig(
                    encoderAdaptor: ModelPaths.funasrEncoder.path,
                    llm: ModelPaths.funasrLLM.path,
                    embedding: ModelPaths.funasrEmbedding.path,
                    tokenizer: ModelPaths.funasrTokenizer.path,
                    maxNewTokens: 512
                ))
        case .qwen3Asr:
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: "",
                numThreads: 4,
                qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
                    convFrontend: ModelPaths.qwen3ConvFrontend.path,
                    encoder: ModelPaths.qwen3Encoder.path,
                    decoder: ModelPaths.qwen3Decoder.path,
                    tokenizer: ModelPaths.qwen3Tokenizer.path,
                    maxNewTokens: 512
                ))
        }
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(),
            modelConfig: modelConfig
        )
        let r = SherpaOnnxOfflineRecognizer(config: &config)
        recognizer = r
        loadedModel = model
        return r
    }

    /// 单段音频转写（16kHz 单声道）。LLM 模型超 20s 时自动 VAD 分段。
    func transcribe(samples: [Float], sampleRate: Int = 16000) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let text = try self.transcribeSync(samples: samples, sampleRate: sampleRate)
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeSync(samples: [Float], sampleRate: Int) throws -> String {
        let r = try loadedRecognizer()
        let duration = Double(samples.count) / Double(max(sampleRate, 1))
        if Self.isLLM(SettingsStore.localAsrModel), duration > Self.llmMaxDirectSeconds {
            let pieces = try Self.vadTranscribe(
                samples: samples, recognizer: r, maxSpeechDuration: 15)
            return pieces.joined(separator: "\n")
        }
        return r.decode(samples: samples, sampleRate: sampleRate).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 文件转写：解码 → silero VAD 分段 → 逐段识别，段间换行
    func transcribeFile(
        url: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        let maxSpeech: Float = Self.isLLM(SettingsStore.localAsrModel) ? 15 : 20
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try self.loadedRecognizer()
                    let pieces = try Self.vadTranscribe(
                        samples: samples, recognizer: r, maxSpeechDuration: maxSpeech,
                        onProgress: onProgress)
                    cont.resume(returning: pieces.joined(separator: "\n"))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// VAD 切分 + 逐段识别。LLM 模型 maxSpeechDuration 取 15s（防 max_total_len 截断），
    /// SenseVoice 沿用 20s。空段自动丢弃。
    private static func vadTranscribe(
        samples: [Float],
        recognizer: SherpaOnnxOfflineRecognizer,
        maxSpeechDuration: Float,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [String] {
        guard ModelPaths.vadPresent else { throw AsrError.vadMissing }
        let silero = sherpaOnnxSileroVadModelConfig(
            model: ModelPaths.vadModel.path,
            threshold: 0.5,
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: maxSpeechDuration
        )
        var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig, buffer_size_in_seconds: 120)

        var pieces: [String] = []
        func drainSegments() {
            while !vad.isEmpty() {
                let seg = vad.front()
                let text = recognizer.decode(samples: seg.samples).text
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
            onProgress?(Double(i) / Double(max(samples.count, 1)))
        }
        vad.flush()
        drainSegments()
        return pieces
    }
}
