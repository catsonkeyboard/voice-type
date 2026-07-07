import Foundation

/// DashScope 实时 ASR WebSocket 协议的纯逻辑部分（无 I/O，可完整单测）。
/// 协议参考: https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api
enum DashScopeAsr {
    static let defaultEndpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!
    static let defaultModel = "fun-asr-realtime"

    struct Sentence: Equatable {
        var text: String
        var sentenceEnd: Bool
    }

    enum ServerEvent: Equatable {
        case taskStarted
        case resultGenerated(Sentence)
        case taskFinished
        case taskFailed(code: String, message: String)
        case unknown
    }

    static func newTaskId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func runTaskMessage(taskId: String, model: String, sampleRate: Int = 16000) -> String {
        let obj: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskId, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": ["format": "pcm", "sample_rate": sampleRate],
                "input": [String: Any](),
            ],
        ]
        return jsonString(obj)
    }

    static func finishTaskMessage(taskId: String) -> String {
        let obj: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskId, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ]
        return jsonString(obj)
    }

    static func parseEvent(_ text: String) -> ServerEvent {
        guard let data = text.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let header = obj["header"] as? [String: Any],
            let event = header["event"] as? String
        else { return .unknown }
        switch event {
        case "task-started":
            return .taskStarted
        case "task-finished":
            return .taskFinished
        case "task-failed":
            return .taskFailed(
                code: header["error_code"] as? String ?? "unknown",
                message: header["error_message"] as? String ?? "未知错误")
        case "result-generated":
            guard let payload = obj["payload"] as? [String: Any],
                let output = payload["output"] as? [String: Any],
                let sentence = output["sentence"] as? [String: Any],
                let text = sentence["text"] as? String
            else { return .unknown }
            return .resultGenerated(
                Sentence(text: text, sentenceEnd: sentence["sentence_end"] as? Bool ?? false))
        default:
            return .unknown
        }
    }

    /// Float32 [-1,1] → 16bit PCM 小端
    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 增量识别结果装配：已定稿句子 + 当前 partial → 实时文本 / 终稿
struct SentenceAssembler {
    private(set) var finalized: [String] = []
    private(set) var partial: String = ""

    mutating func ingest(_ sentence: DashScopeAsr.Sentence) {
        if sentence.sentenceEnd {
            if !sentence.text.isEmpty { finalized.append(sentence.text) }
            partial = ""
        } else {
            partial = sentence.text
        }
    }

    var liveText: String {
        (finalized + (partial.isEmpty ? [] : [partial])).joined()
    }

    /// finish 时残留的 partial 并入终稿（服务端可能不给最后一句发 sentence_end）
    var finalText: String { liveText }
}
