import XCTest

@testable import VoiceType

/// 本地 ASR 档位基准（v7）：对 benchmark_samples/ 下用户自录的中英混说
/// wav 逐档转写，输出「模型 × 样本 × RTF × 文本」表并断言 RTF < 3.0。
///
/// 用途：第四档（FireRedASR2-CTC）转正门禁 + 未来换默认档的依据。
/// 样本目录缺失或无 wav 时整体跳过（XCTSkip）——样本是用户自录语音，不入库。
///
/// 用法：把 ≥5 条中英混说 wav 放进项目根的 benchmark_samples/，
/// 然后正常运行测试（xcodebuild 或 scripts/run_tests.sh AsrBenchmarkTests）。
final class AsrBenchmarkTests: XCTestCase {
    /// 听写可用性底线：识别耗时 / 音频时长
    private static let maxRTF: Double = 3.0

    private static var samplesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VoiceTypeTests/
            .deletingLastPathComponent()  // 项目根
            .appendingPathComponent("benchmark_samples", isDirectory: true)
    }

    private func loadSamples() throws -> [(name: String, samples: [Float])] {
        let dir = Self.samplesDir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw XCTSkip("基准样本目录不存在：\(dir.path)（放入自录中英混说 wav 后重跑）")
        }
        let wavs = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        .filter { ["wav", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !wavs.isEmpty else {
            throw XCTSkip("基准样本目录为空：\(dir.path)")
        }
        return try wavs.map { ($0.deletingPathExtension().lastPathComponent, try AudioFileDecoder.decode16kMono(url: $0)) }
    }

    func testBenchmarkAllInstalledModels() async throws {
        let samples = try loadSamples()
        let installed = LocalAsrModel.allCases.filter { ModelPaths.isPresent($0) }
        try XCTSkipUnless(
            !installed.isEmpty, "无已安装模型，跳过基准（先跑 scripts/download_models.sh）")

        let original = SettingsStore.localAsrModel
        defer { SettingsStore.localAsrModel = original }

        print("═══ ASR 基准（\(samples.count) 样本 × \(installed.count) 模型，RTF 上限 \(Self.maxRTF)）═══")
        for model in installed {
            SettingsStore.localAsrModel = model
            let service = AsrService()
            service.warmUp()
            for sample in samples {
                let duration = Double(sample.samples.count) / 16000.0
                let started = Date()
                let text = try await service.transcribe(samples: sample.samples)
                let elapsed = Date().timeIntervalSince(started)
                let rtf = elapsed / max(duration, 0.1)
                let preview = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                print(String(
                    format: "%-28s %-20s 时长 %5.1fs 耗时 %5.2fs RTF %5.2f | %@",
                    (model.label as NSString).utf8String!,
                    (sample.name as NSString).utf8String!,
                    duration, elapsed, rtf, preview))
                XCTAssertLessThan(
                    rtf, Self.maxRTF,
                    "\(model.label) 对 \(sample.name) 的 RTF \(rtf) 超过 \(Self.maxRTF)")
            }
            print("─".repeated(72))
        }
    }
}

private extension String {
    func repeated(_ n: Int) -> String {
        String(repeating: self, count: n)
    }
}
