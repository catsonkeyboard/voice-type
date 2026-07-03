import AVFoundation
import XCTest

@testable import VoiceType

final class AudioFileDecoderTests: XCTestCase {
    /// 生成 44.1kHz 立体声 1 秒正弦波 wav，解码后应得到约 16000 个单声道采样
    func testDecodeResamplesTo16kMono() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // 写入作用域结束后 AVAudioFile 才会 flush 关闭，故用局部函数包裹
        func writeFixture() throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames: AVAudioFrameCount = 44100
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for ch in 0..<2 {
                let p = buf.floatChannelData![ch]
                for i in 0..<Int(frames) {
                    p[i] = sinf(2 * .pi * 440 * Float(i) / 44100) * 0.5
                }
            }
            try file.write(from: buf)
        }
        try writeFixture()

        let samples = try AudioFileDecoder.decode16kMono(url: url)

        XCTAssertGreaterThan(samples.count, 15200)
        XCTAssertLessThan(samples.count, 16800)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testDecodeMissingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/file.wav")
        XCTAssertThrowsError(try AudioFileDecoder.decode16kMono(url: url))
    }
}
