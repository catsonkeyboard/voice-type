// 模型切换内存验证：同一进程内 加载→卸载→加载，逐步打印 phys_footprint
// 编译需带 bridging header（见 README 或直接跑：文件名必须是 main.swift）
import Foundation

let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("VoiceType/models")

func residentMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
}

func config(_ which: String) -> SherpaOnnxOfflineRecognizerConfig {
    let mc: SherpaOnnxOfflineModelConfig
    switch which {
    case "funasr":
        let d = modelsDir.appendingPathComponent("funasr-nano")
        mc = sherpaOnnxOfflineModelConfig(
            tokens: "", numThreads: 4,
            funasrNano: sherpaOnnxOfflineFunASRNanoModelConfig(
                encoderAdaptor: d.appendingPathComponent("encoder_adaptor.int8.onnx").path,
                llm: d.appendingPathComponent("llm.int8.onnx").path,
                embedding: d.appendingPathComponent("embedding.int8.onnx").path,
                tokenizer: d.appendingPathComponent("Qwen3-0.6B").path,
                maxNewTokens: 512))
    default:
        mc = sherpaOnnxOfflineModelConfig(
            tokens: modelsDir.appendingPathComponent("tokens.txt").path,
            numThreads: 4,
            senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                model: modelsDir.appendingPathComponent("model.int8.onnx").path,
                language: "auto", useInverseTextNormalization: true))
    }
    return sherpaOnnxOfflineRecognizerConfig(
        featConfig: sherpaOnnxFeatureConfig(), modelConfig: mc)
}

func load(_ which: String) -> SherpaOnnxOfflineRecognizer {
    var cfg = config(which)
    return SherpaOnnxOfflineRecognizer(config: &cfg)
}

func settle(_ ms: UInt32 = 500) { usleep(ms * 1000) }

print(String(format: "进程基线: %.0f MB", residentMB()))
settle()

var recognizer: SherpaOnnxOfflineRecognizer? = load("funasr")
settle(1000)
print(String(format: "加载 funasr-nano 后: %.0f MB", residentMB()))

recognizer = nil  // 卸载：deinit → SherpaOnnxDestroyOfflineRecognizer
settle(1000)
print(String(format: "卸载 funasr-nano 后: %.0f MB", residentMB()))

recognizer = load("sense")
settle(1000)
print(String(format: "加载 SenseVoice 后: %.0f MB", residentMB()))

recognizer = nil
settle(1000)
print(String(format: "卸载 SenseVoice 后: %.0f MB", residentMB()))

recognizer = load("funasr")
settle(1000)
print(String(format: "再次加载 funasr-nano 后: %.0f MB", residentMB()))
recognizer = nil
print("✓ 切换链路验证完成")
