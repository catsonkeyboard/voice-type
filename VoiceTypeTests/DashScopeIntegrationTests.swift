import XCTest

@testable import VoiceType

/// 真实端点集成测试：需要 DASHSCOPE_API_KEY 环境变量或 Keychain 中已存 Key，否则跳过。
final class DashScopeIntegrationTests: XCTestCase {
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !env.isEmpty {
            return env
        }
        return KeychainStore.get("dashscope-api-key") ?? ""
    }

    func testRealtimeTranscription() async throws {
        try XCTSkipUnless(!Self.apiKey.isEmpty, "无 DASHSCOPE_API_KEY，跳过云端集成测试")
        let wav = AsrServiceTests.testWav
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wav.path), "测试音频不存在")

        let samples = try AudioFileDecoder.decode16kMono(url: wav)
        let session = DashScopeAsrSession(apiKey: Self.apiKey, model: DashScopeAsr.defaultModel)
        let partialFired = expectation(description: "partial 至少触发一次")
        partialFired.assertForOverFulfill = false
        session.onPartial = { _ in partialFired.fulfill() }

        try await session.start()
        var i = 0
        while i < samples.count {
            let end = min(i + 1600, samples.count)
            session.send(samples: Array(samples[i..<end]))
            i = end
        }
        let text = try await session.finish()
        print("DashScope 终稿: \(text)")
        await fulfillment(of: [partialFired], timeout: 1)
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        XCTAssertGreaterThanOrEqual(cjk, 4, "云端应识别出中文，实际: \(text)")
    }

    func testInvalidKeyFailsFast() async throws {
        try XCTSkipUnless(!Self.apiKey.isEmpty, "无网络凭据环境，跳过")
        let session = DashScopeAsrSession(apiKey: "sk-invalid-key", model: DashScopeAsr.defaultModel)
        do {
            try await session.start()
            XCTFail("无效 Key 应失败")
        } catch {}
    }
}
