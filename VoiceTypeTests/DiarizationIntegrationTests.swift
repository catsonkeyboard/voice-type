import AVFoundation
import XCTest

@testable import VoiceType

/// 说话人分离集成测试：拼接两个不同说话人的本地示例音频。
/// 分离模型或 ASR 模型缺失时自动跳过。
final class DiarizationIntegrationTests: XCTestCase {
    static let speakerA = AsrServiceTests.testWav  // 男声（paraformer 示例）
    static let speakerB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/modelscope/hub/models/iic/SenseVoiceSmall/example/zh.mp3")

    private func requireModels() throws {
        try XCTSkipUnless(ModelPaths.diarizationPresent, "分离模型未安装，跳过")
        try XCTSkipUnless(ModelPaths.allPresent, "ASR 模型未安装，跳过")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.speakerA.path)
                && FileManager.default.fileExists(atPath: Self.speakerB.path),
            "测试音频不存在，跳过")
    }

    /// 生成两说话人拼接音频：A(≤6s) + 0.8s 静音 + B(≤6s)
    private func makeTwoSpeakerAudio() throws -> (samples: [Float], url: URL) {
        let a = try AudioFileDecoder.decode16kMono(url: Self.speakerA)
        let b = try AudioFileDecoder.decode16kMono(url: Self.speakerB)
        let cap = 6 * 16000
        var samples = Array(a.prefix(cap))
        samples += [Float](repeating: 0, count: 12800)
        samples += Array(b.prefix(cap))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-speaker-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return (samples, url)
    }

    func testDiarizeTwoSpeakers() async throws {
        try requireModels()
        let (samples, url) = try makeTwoSpeakerAudio()
        defer { try? FileManager.default.removeItem(at: url) }

        let service = DiarizationService()
        let segments = try await service.diarize(samples: samples, numSpeakers: 2)
        print("分离结果: \(segments)")
        XCTAssertGreaterThanOrEqual(Set(segments.map(\.speaker)).count, 2, "应分离出两位说话人")
    }

    func testMeetingProcessorEndToEnd() async throws {
        try requireModels()
        let (_, url) = try makeTwoSpeakerAudio()
        defer { try? FileManager.default.removeItem(at: url) }

        let processor = MeetingProcessor(asr: AsrService())
        let (transcript, jsonURL) = try await processor.process(
            url: url, numSpeakers: 2, onProgress: { _, _ in })
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        print("会议稿:\n\(transcript.markdown())")
        XCTAssertFalse(transcript.degraded, "不应降级")
        XCTAssertGreaterThanOrEqual(transcript.speakerIds.count, 2)
        XCTAssertTrue(transcript.segments.allSatisfy { !$0.text.isEmpty })
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
    }
}
