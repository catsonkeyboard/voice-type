#!/usr/bin/env swift
// DashScope Fun-ASR-Realtime 协议探针：
//   DASHSCOPE_API_KEY=sk-xxx swift scripts/probe_dashscope.swift [wav文件路径]
// 打印全部服务端原始 JSON 事件，用于核对解析器字段。
import AVFoundation
import Foundation

let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] ?? ""
guard !apiKey.isEmpty else {
    print("用法: DASHSCOPE_API_KEY=sk-xxx swift scripts/probe_dashscope.swift [wav]")
    exit(1)
}
let wavPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/.cache/modelscope/hub/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch/asr_example_hotword.wav").expandingTildeInPath

// wav → 16k mono Float32
func decode16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let dst = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: dst)!
    var result: [Float] = []
    var eof = false
    let input: AVAudioConverterInputBlock = { _, status in
        if eof { status.pointee = .endOfStream; return nil }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        try? file.read(into: buf)
        if buf.frameLength == 0 { eof = true; status.pointee = .endOfStream; return nil }
        status.pointee = .haveData
        return buf
    }
    while true {
        let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192)!
        var err: NSError?
        let st = converter.convert(to: out, error: &err, withInputFrom: input)
        if out.frameLength > 0 {
            result.append(
                contentsOf: UnsafeBufferPointer(
                    start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        if st == .endOfStream || st == .error { break }
    }
    return result
}

func pcm16(_ samples: ArraySlice<Float>) -> Data {
    var d = Data(capacity: samples.count * 2)
    for s in samples {
        let v = Int16(max(-1, min(1, s)) * 32767)
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

let samples = try decode16k(wavPath)
print("音频: \(samples.count) samples (\(Double(samples.count) / 16000)s)")

let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!)
request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
let socket = URLSession.shared.webSocketTask(with: request)
socket.resume()

let done = DispatchSemaphore(value: 0)
func receive() {
    socket.receive { result in
        switch result {
        case .failure(let e):
            print("❌ 接收错误: \(e)")
            done.signal()
        case .success(.string(let text)):
            print("<<< \(text)")
            if text.contains("task-finished") || text.contains("task-failed") {
                done.signal()
            } else {
                receive()
            }
        case .success:
            receive()
        }
    }
}
receive()

let runTask = """
    {"header":{"action":"run-task","task_id":"\(taskId)","streaming":"duplex"},"payload":{"task_group":"audio","task":"asr","function":"recognition","model":"fun-asr-realtime","parameters":{"format":"pcm","sample_rate":16000},"input":{}}}
    """
print(">>> run-task")
socket.send(.string(runTask)) { if let e = $0 { print("❌ \(e)") } }
Thread.sleep(forTimeInterval: 1)

var i = 0
while i < samples.count {
    let end = min(i + 1600, samples.count)
    socket.send(.data(pcm16(samples[i..<end]))) { if let e = $0 { print("❌ \(e)") } }
    i = end
    Thread.sleep(forTimeInterval: 0.02)
}
print(">>> finish-task")
let finishTask = """
    {"header":{"action":"finish-task","task_id":"\(taskId)","streaming":"duplex"},"payload":{"input":{}}}
    """
socket.send(.string(finishTask)) { if let e = $0 { print("❌ \(e)") } }

_ = done.wait(timeout: .now() + 30)
socket.cancel(with: .normalClosure, reason: nil)
print("完成")
