import XCTest

@testable import VoiceType

/// 金标集成测试：验证真实模型的四项核心能力。
/// Ollama 未运行或模型未下载时自动跳过（提示 pull 命令）。
final class PolishIntegrationTests: XCTestCase {
    static let model = "qwen3.5:4b-nvfp4"

    private func makeService() -> PolishService {
        PolishService(configProvider: {
            PolishConfig(
                enabled: true, baseURL: "http://localhost:11434/v1", apiKey: "",
                model: Self.model, style: .clean)
        })
    }

    /// 前置检查 + 预热（首次加载模型可能较慢，先打一发让正式请求走热路径）
    private func requireModel(_ service: PolishService) async throws {
        let probe = await service.probe()
        try XCTSkipUnless(probe.reachable, "Ollama 未运行，跳过集成测试")
        try XCTSkipUnless(
            probe.models.contains(Self.model),
            "模型未下载，请运行: ollama pull \(Self.model)")
        _ = await service.polish("预热请求，请原样输出这句话。")
    }

    func testGoldenFillerRemoval() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("嗯我觉得这个方案就是说还有一些问题那个性能方面可能得再优化一下")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-口头禅: \(result)")
        XCTAssertFalse(result.contains("嗯"))
        XCTAssertFalse(result.contains("就是说"))
        XCTAssertFalse(result.contains("那个"))
        XCTAssertTrue(result.contains("性能"))
    }

    func testGoldenSelfCorrection() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("明天下午呃不对是明天上午九点开会")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-自我纠正: \(result)")
        XCTAssertTrue(result.contains("上午"))
        XCTAssertFalse(result.contains("下午"))
        XCTAssertFalse(result.contains("不对"))
    }

    func testGoldenListFormatting() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("买菜清单第一个是西红柿第二个是鸡蛋第三个是牛奶")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-列表化: \(result)")
        for item in ["西红柿", "鸡蛋", "牛奶"] {
            XCTAssertTrue(result.contains(item), "缺少列举项 \(item)")
        }
        XCTAssertTrue(
            result.contains("1.") || result.contains("- "),
            "未格式化为列表: \(result)")
    }

    func testGoldenFluency() async throws {
        let service = makeService()
        try await requireModel(service)
        let out = await service.polish("这个 bug 呃我看了一下应该是 cache 没有 invalidate 导致的")
        let result = try XCTUnwrap(out, "润色返回 nil")
        print("金标-连贯化: \(result)")
        XCTAssertFalse(result.contains("呃"))
        XCTAssertTrue(result.contains("cache"))
        XCTAssertTrue(result.contains("invalidate"))
    }
}
