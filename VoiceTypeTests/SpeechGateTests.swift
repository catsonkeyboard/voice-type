import XCTest

@testable import VoiceType

final class SpeechGateTests: XCTestCase {
    private let rate = 16000

    /// `seconds` 秒的静音
    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// 在 `samples` 的 `start` 秒处写入一段 `seconds` 秒、幅度 `amplitude` 的 220 Hz 正弦（模拟人声能量）
    private func tone(_ samples: inout [Float], start: Double, seconds: Double, amplitude: Float) {
        let from = Int(start * Double(rate))
        let count = Int(seconds * Double(rate))
        for i in 0..<count where from + i < samples.count {
            samples[from + i] = amplitude * sin(2 * .pi * 220 * Float(i) / Float(rate))
        }
    }

    /// 确定性的弱噪声（线性同余），幅度不超过 `amplitude`
    private func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return (Float(state >> 16 & 0x7FFF) / 32767 * 2 - 1) * amplitude
        }
    }

    func testSilenceAndFaintNoiseHaveNoSpeech() {
        XCTAssertFalse(SpeechGate.hasSpeech(silence(1)))
        XCTAssertFalse(SpeechGate.hasSpeech(noise(1, amplitude: 0.004)))
    }

    func testAKeyClickIsNotSpeech() {
        // 按键声：一声 30 ms 的短促响动
        var samples = silence(1)
        tone(&samples, start: 0.4, seconds: 0.03, amplitude: 0.3)
        XCTAssertFalse(SpeechGate.hasSpeech(samples))
    }

    func testAShortBurstBelowTheMinimumIsNotSpeech() {
        var samples = silence(1)
        tone(&samples, start: 0.3, seconds: 0.12, amplitude: 0.1)
        XCTAssertFalse(SpeechGate.hasSpeech(samples))
    }

    func testAShortWordIsSpeech() {
        // 一个字（「好」）大约 0.2–0.3 秒
        var samples = silence(1)
        tone(&samples, start: 0.3, seconds: 0.25, amplitude: 0.05)
        XCTAssertTrue(SpeechGate.hasSpeech(samples))
    }

    func testSpeechOverFaintNoiseIsSpeech() {
        var samples = noise(2, amplitude: 0.004)
        tone(&samples, start: 0.5, seconds: 0.8, amplitude: 0.08)
        XCTAssertTrue(SpeechGate.hasSpeech(samples))
    }

    func testStripsSilenceTokens() {
        XCTAssertEqual(SpeechGate.stripSilenceTokens("/sil"), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens(" /sil "), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("你好 /sil"), "你好")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("<sil>好的"), "好的")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("[SIL] 明天见"), "明天见")
    }

    func testKeepsWordsThatOnlyContainSil() {
        XCTAssertEqual(SpeechGate.stripSilenceTokens("silver /silent"), "silver /silent")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("帮我打开 silo"), "帮我打开 silo")
    }
}
