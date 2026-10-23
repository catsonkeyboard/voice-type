import Foundation

/// 听写送去识别之前的把关。
///
/// 识别模型面对纯噪音会「幻听」：连按两下说话键、只录到按键声或底噪时，
/// 会识别出 `the`、`你。`、`/sil` 这类没人说过的文字（2026-10-23 实测）。
/// 所以识别前先看录音里有没有足够长的人声；识别后再去掉漏出来的静音标记。
enum SpeechGate {
    /// 一帧 30 ms（16 kHz 下 480 个采样）
    static let frameSeconds = 0.03
    /// 音量（均方根）高于这个值的帧才算有声音，约 −40 dBFS；室内底噪远低于它，正常说话远高于它
    static let voicedLevel: Float = 0.01
    /// 有声音的帧合计至少这么长才算有人说话；一声按键只有一两帧
    static let minVoicedSeconds = 0.15

    /// 纯函数：录音里有没有足够长的人声
    static func hasSpeech(_ samples: [Float], sampleRate: Int = 16000) -> Bool {
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let needed = Int((minVoicedSeconds / frameSeconds).rounded(.up))
        var voiced = 0
        var start = 0
        while start < samples.count {
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            let level = (sum / Float(end - start)).squareRoot()
            if level >= voicedLevel {
                voiced += 1
                if voiced >= needed { return true }
            }
            start = end
        }
        return false
    }

    /// 识别结果里可能漏出的静音标记：`/sil`、`<sil>`、`[sil]`（不分大小写）。
    /// `/silent`、`silver` 这类正常单词不受影响。
    private static let silenceToken = try! NSRegularExpression(
        pattern: #"(?i)(?:/sil\b|<sil>|\[sil\])"#)
    private static let extraSpaces = try! NSRegularExpression(pattern: " {2,}")

    /// 纯函数：去掉静音标记，并收拢因此多出的空格、去掉首尾空白
    static func stripSilenceTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let removed = silenceToken.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
        let collapsed = extraSpaces.stringByReplacingMatches(
            in: removed, range: NSRange(removed.startIndex..., in: removed), withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
