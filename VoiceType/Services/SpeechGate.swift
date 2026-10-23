import Foundation

/// 听写送去识别之前的把关。
///
/// 识别模型面对纯噪音会「幻听」：连按两下说话键、只录到按键声或底噪时，
/// 会识别出 `the`、`你。`、`/sil` 这类没人说过的文字（2026-10-23 实测）。
/// 所以识别前先看录音里有没有一段连续的人声；识别后再去掉漏出来的静音标记。
enum SpeechGate {
    /// 一帧 30 ms（16 kHz 下 480 个采样）
    static let frameSeconds = 0.03
    /// 音量（均方根）不低于这个值的帧才算有声音，约 −40 dBFS
    static let voicedLevel: Float = 0.01
    /// 连续有声音至少这么长才算有人说话。一声按键只有一两帧，一个字也有 0.2 秒以上
    static let minVoicedSeconds = 0.15
    /// 连续段里允许夹这么多帧安静（字与字之间的短停顿）
    static let hangoverFrames = 1
    /// 不看录音最后这一段：结束录音时按快捷键的按键声落在这里
    static let tailIgnoredSeconds = 0.15

    /// 一段录音的人声情况，被挡掉时写进日志（只有数字，不含内容）
    struct Analysis: Equatable {
        /// 最长的连续有声段（秒）
        var longestRunSeconds: Double
        /// 最响一帧的音量
        var peakLevel: Float

        var hasSpeech: Bool { longestRunSeconds >= SpeechGate.minVoicedSeconds - 1e-9 }
    }

    /// 纯函数：逐帧算音量，找出最长的连续有声段（忽略结尾的按键声）
    static func analyze(_ samples: [Float], sampleRate: Int = 16000) -> Analysis {
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let usable = max(0, samples.count - Int(tailIgnoredSeconds * Double(sampleRate)))
        var run = 0
        var gap = 0
        var longest = 0
        var peak: Float = 0
        var start = 0
        while start < usable {
            let end = min(start + frame, usable)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            let level = (sum / Float(end - start)).squareRoot()
            peak = max(peak, level)
            if level >= voicedLevel {
                // 段内的短停顿算进这一段
                if run > 0 { run += gap }
                run += 1
                gap = 0
                longest = max(longest, run)
            } else if run > 0 {
                gap += 1
                if gap > hangoverFrames {
                    run = 0
                    gap = 0
                }
            }
            start = end
        }
        return Analysis(longestRunSeconds: Double(longest) * frameSeconds, peakLevel: peak)
    }

    /// 纯函数：录音里有没有足够长的连续人声
    static func hasSpeech(_ samples: [Float], sampleRate: Int = 16000) -> Bool {
        analyze(samples, sampleRate: sampleRate).hasSpeech
    }

    /// 识别结果里可能漏出的静音标记：`/sil`、`<sil>`、`[sil]`（不分大小写）。
    /// 后面紧跟中文或标点也算；`/silent`、`silver` 这类英文单词不受影响。
    private static let silenceToken = try! NSRegularExpression(
        pattern: #"(?i)(?:/sil(?![A-Za-z0-9_])|<sil>|\[sil\])"#)
    private static let extraSpaces = try! NSRegularExpression(pattern: " {2,}")

    /// 纯函数：去掉静音标记，收拢因此多出的空格、去掉首尾空白；只剩标点时返回空串
    static func stripSilenceTokens(_ text: String) -> String {
        let removed = silenceToken.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let collapsed = extraSpaces.stringByReplacingMatches(
            in: removed, range: NSRange(removed.startIndex..., in: removed), withTemplate: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningful = trimmed.unicodeScalars.contains {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return meaningful ? trimmed : ""
    }
}
