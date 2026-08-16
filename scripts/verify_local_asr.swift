// 独立编译的本地识别验证工具：对三档模型各跑一次真实推理
// 用法: swift scripts/verify_local_asr.swift <funasr|qwen3|sense> <wav路径>
import Foundation

let modelArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "funasr"
let wavPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let dylibDir = root.appendingPathComponent("Vendor/sherpa-onnx/lib")
setenv("DYLD_LIBRARY_PATH", dylibDir.path, 1)  // @main

let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("VoiceType/models")

func makeConfig(_ which: String) -> SherpaOnnxOfflineRecognizerConfig? {
    var mc = SherpaOnnxOfflineModelConfig()
    switch which {
    case "funasr":
        let dir = modelsDir.appendingPathComponent("funasr-nano")
        mc = sherpaOnnxOfflineModelConfig(
            tokens: "", numThreads: 4,
            funasrNano: sherpaOnnxOfflineFunASRNanoModelConfig(
                encoderAdaptor: dir.appendingPathComponent("encoder_adaptor.int8.onnx").path,
                llm: dir.appendingPathComponent("llm.int8.onnx").path,
                embedding: dir.appendingPathComponent("embedding.int8.onnx").path,
                tokenizer: dir.appendingPathComponent("Qwen3-0.6B").path,
                maxNewTokens: 512))
    case "qwen3":
        let dir = modelsDir.appendingPathComponent("qwen3-asr")
        mc = sherpaOnnxOfflineModelConfig(
            tokens: "", numThreads: 4,
            qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(
                convFrontend: dir.appendingPathComponent("conv_frontend.onnx").path,
                encoder: dir.appendingPathComponent("encoder.int8.onnx").path,
                decoder: dir.appendingPathComponent("decoder.int8.onnx").path,
                tokenizer: dir.appendingPathComponent("tokenizer").path,
                maxNewTokens: 512))
    case "sense":
        mc = sherpaOnnxOfflineModelConfig(
            tokens: modelsDir.appendingPathComponent("tokens.txt").path,
            numThreads: 4,
            senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                model: modelsDir.appendingPathComponent("model.int8.onnx").path,
                language: "auto", useInverseTextNormalization: true))
    default:
        return nil
    }
    return sherpaOnnxOfflineRecognizerConfig(
        featConfig: sherpaOnnxFeatureConfig(), modelConfig: mc)
}

// 解码 wav → 16k mono（复用 AVFoundation）
import AVFoundation
func decode16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let src = file.processingFormat
    let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: src, to: dst)!
    var out: [Float] = []
    var eof = false
    let block: AVAudioConverterInputBlock = { _, status in
        if eof { status.pointee = .endOfStream; return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 8192) else {
            status.pointee = .endOfStream; return nil
        }
        do { try file.read(into: buf) } catch { eof = true; status.pointee = .endOfStream; return nil }
        if buf.frameLength == 0 { eof = true; status.pointee = .endOfStream; return nil }
        status.pointee = .haveData; return buf
    }
    while true {
        let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192)!
        var err: NSError?
        let st = conv.convert(to: outBuf, error: &err, withInputFrom: block)
        if outBuf.frameLength > 0 {
            out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
        }
        if st == .endOfStream { break }
        if st == .error { throw err ?? NSError(domain: "conv", code: 1) }
    }
    return out
}


guard var config = makeConfig(modelArg), !modelArg.isEmpty else {
    print("未知模型: \(modelArg)")
    exit(1)
}
let name = modelArg
let wavURL = URL(fileURLWithPath: wavPath.isEmpty ? "\(modelsDir.path)/funasr-nano/test_wavs/dia_hunan.wav" : wavPath)
print("模型: \(name)")
print("音频: \(wavURL.lastPathComponent)")
let samples = try decode16k(wavURL)
print("时长: \(String(format: "%.1f", Double(samples.count)/16000.0))s")
let t0 = Date()
let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
print("模型加载: \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")

let t1 = Date()
let result = recognizer.decode(samples: samples)
let infer = -t1.timeIntervalSinceNow
print("推理耗时: \(String(format: "%.2f", infer))s (RTF \(String(format: "%.3f", infer / (Double(samples.count)/16000.0))))")
print("识别结果: \(result.text)")
print("✓ \(name) 验证通过")
