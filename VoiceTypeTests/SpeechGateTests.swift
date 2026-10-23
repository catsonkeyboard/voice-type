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

    func testExactlyTheMinimumRunIsSpeech() {
        // 0.3 秒处对齐帧边界：0.15 秒正好 5 帧
        var samples = silence(1)
        tone(&samples, start: 0.3, seconds: 0.15, amplitude: 0.1)
        XCTAssertTrue(SpeechGate.hasSpeech(samples))
    }

    func testTwoClicksApartAreNotSpeech() {
        // 连按两下：两团按键声各 3 帧，中间隔开，不能加起来算人声
        var samples = silence(1)
        tone(&samples, start: 0.2, seconds: 0.09, amplitude: 0.3)
        tone(&samples, start: 0.5, seconds: 0.09, amplitude: 0.3)
        XCTAssertFalse(SpeechGate.hasSpeech(samples))
    }

    func testAClickAtTheVeryEndIsIgnored() {
        // 结束录音时的按键声落在最后 0.15 秒
        var samples = silence(1)
        tone(&samples, start: 0.86, seconds: 0.14, amplitude: 0.3)
        XCTAssertFalse(SpeechGate.hasSpeech(samples))
    }

    func testSyllablesWithAShortPauseCountAsOneRun() {
        // 两个音节各 3 帧，中间停 1 帧
        var samples = silence(1)
        tone(&samples, start: 0.3, seconds: 0.09, amplitude: 0.1)
        tone(&samples, start: 0.42, seconds: 0.09, amplitude: 0.1)
        XCTAssertTrue(SpeechGate.hasSpeech(samples))
    }

    func testEmptyRecordingHasNoSpeech() {
        XCTAssertFalse(SpeechGate.hasSpeech([]))
        XCTAssertEqual(SpeechGate.analyze([]), SpeechGate.Analysis(longestRunSeconds: 0, peakLevel: 0))
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

    func testFeedingInChunksMatchesAnalyzingAtOnce() {
        var samples = noise(2, amplitude: 0.004)
        tone(&samples, start: 0.5, seconds: 0.4, amplitude: 0.08)
        tone(&samples, start: 1.2, seconds: 0.1, amplitude: 0.3)
        var tracker = SpeechGate.Tracker()
        var offset = 0
        for size in [100, 1000, 333, 4096, 7] where offset < samples.count {
            let end = min(offset + size, samples.count)
            tracker.feed(samples[offset..<end])
            offset = end
        }
        tracker.feed(samples[offset...])
        tracker.finish()
        XCTAssertEqual(tracker.analysis, SpeechGate.analyze(samples + silence(SpeechGate.tailIgnoredSeconds)))
    }

    func testNobodySpeaksForThirtySeconds() {
        var tracker = SpeechGate.Tracker()
        tracker.feed(noise(29.9, amplitude: 0.004)[...])
        XCTAssertEqual(SpeechGate.watch(tracker), .keepGoing)
        tracker.feed(noise(0.2, amplitude: 0.004)[...])
        XCTAssertEqual(SpeechGate.watch(tracker), .noSpeech)
    }

    func testQuietForFifteenSecondsAfterSpeaking() {
        var speech = silence(1)
        tone(&speech, start: 0.2, seconds: 0.6, amplitude: 0.08)
        var tracker = SpeechGate.Tracker()
        tracker.feed(speech[...])
        tracker.feed(noise(14.5, amplitude: 0.004)[...])
        // 说完 0.2 秒 + 14.5 秒，还不到 15 秒
        XCTAssertEqual(SpeechGate.watch(tracker), .keepGoing)
        tracker.feed(noise(0.5, amplitude: 0.004)[...])
        XCTAssertEqual(SpeechGate.watch(tracker), .wentQuiet)
    }

    func testAPauseShorterThanFifteenSecondsKeepsRecording() {
        var tracker = SpeechGate.Tracker()
        var first = silence(1)
        tone(&first, start: 0.2, seconds: 0.6, amplitude: 0.08)
        tracker.feed(first[...])
        tracker.feed(silence(10)[...])
        var second = silence(1)
        tone(&second, start: 0.1, seconds: 0.6, amplitude: 0.08)
        tracker.feed(second[...])
        tracker.feed(silence(10)[...])
        XCTAssertEqual(SpeechGate.watch(tracker), .keepGoing)
    }

    func testStripsSilenceTokens() {
        XCTAssertEqual(SpeechGate.stripSilenceTokens("/sil"), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens(" /sil "), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("你好 /sil"), "你好")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("<sil>好的"), "好的")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("[SIL] 明天见"), "明天见")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("/sil你好"), "你好")
    }

    func testOnlyPunctuationLeftCountsAsNothingSaid() {
        XCTAssertEqual(SpeechGate.stripSilenceTokens("/sil。"), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("/sil."), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("。"), "")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("好。"), "好。")
    }

    func testKeepsWordsThatOnlyContainSil() {
        XCTAssertEqual(SpeechGate.stripSilenceTokens("silver /silent"), "silver /silent")
        XCTAssertEqual(SpeechGate.stripSilenceTokens("帮我打开 silo"), "帮我打开 silo")
    }
}
