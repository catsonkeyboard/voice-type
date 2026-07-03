import XCTest

@testable import VoiceType

final class AsrServiceTests: XCTestCase {
    static let testWav = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            ".cache/modelscope/hub/models/iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch/asr_example_hotword.wav"
        )

    private func requireModels() throws {
        try XCTSkipUnless(
            ModelPaths.allPresent,
            "模型未安装，请先运行 scripts/export_model.sh")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.testWav.path),
            "测试音频不存在")
    }

    func testTranscribeChineseWav() async throws {
        try requireModels()
        let samples = try AudioFileDecoder.decode16kMono(url: Self.testWav)
        let service = AsrService()
        let text = try await service.transcribe(samples: samples)
        print("ASR 结果: \(text)")
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "应识别出中文文本，实际: \(text)")
    }

    func testTranscribeFileWithVad() async throws {
        try requireModels()
        let service = AsrService()
        let text = try await service.transcribeFile(url: Self.testWav) { _ in }
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "VAD 文件转写应有中文，实际: \(text)")
    }

    func testTranscribeThrowsWhenModelMissing() async {
        guard !ModelPaths.allPresent else { return }
        let service = AsrService()
        do {
            _ = try await service.transcribe(samples: [Float](repeating: 0, count: 16000))
            XCTFail("应抛出模型缺失错误")
        } catch {}
    }
}
