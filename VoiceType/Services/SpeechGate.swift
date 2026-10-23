import Foundation

/// 听写的人声把关。
///
/// 识别模型面对纯噪音会「幻听」：连按两下说话键、只录到按键声或底噪时，
/// 会识别出 `the`、`你。`、`/sil` 这类没人说过的文字（2026-10-23 实测）。
/// 所以识别前先看录音里有没有一段连续的人声；识别后再去掉漏出来的静音标记。
/// 录音过程中也用同一套判断：开头一直没人说话、或说完后长时间安静，就自动结束。
enum SpeechGate {
    /// 一帧 30 ms（16 kHz 下 480 个采样）
    static let frameSeconds = 0.03
    /// 音量（均方根）不低于这个值的帧才算有声音，约 −40 dBFS
    static let voicedLevel: Float = 0.01
    /// 连续有声音至少这么长才算有人说话。一声按键只有一两帧，一个字也有 0.2 秒以上
    static let minVoicedSeconds = 0.15
    /// 连续段里允许夹这么多帧安静（字与字之间的短停顿）
    static let hangoverFrames = 1
    /// 录完后判断时不看最后这一段：结束录音时按快捷键的按键声落在这里
    static let tailIgnoredSeconds = 0.15
    /// 开头这么久一直没有人声，就自动结束录音（用户 2026-10-23 选定 30 秒）
    static let noSpeechTimeoutSeconds = 30.0
    /// 说过话之后连续安静这么久，就当作说完了，自动结束录音（用户 2026-10-23 选定 15 秒）
    static let trailingSilenceSeconds = 15.0

    /// 一段录音的人声情况，被挡掉时写进日志（只有数字，不含内容）
    struct Analysis: Equatable {
        /// 最长的连续有声段（秒）
        var longestRunSeconds: Double
        /// 最响一帧的音量
        var peakLevel: Float

        var hasSpeech: Bool { longestRunSeconds >= SpeechGate.minVoicedSeconds - 1e-9 }
    }

    /// 逐帧跟踪人声，可以一块块喂（录音过程中），也可以一次喂完（录音结束后）
    struct Tracker {
        private let frameSize: Int
        /// 还凑不满一帧的采样，等下一块来了再算
        private var pending: [Float] = []
        private var frames = 0
        private var run = 0
        private var gap = 0
        private var longestRun = 0
        private var peak: Float = 0
        /// 最近一个有声帧结束时的帧数
        private var lastVoicedFrameEnd = 0

        init(sampleRate: Int = 16000) {
            frameSize = max(1, Int(SpeechGate.frameSeconds * Double(sampleRate)))
        }

        mutating func feed(_ samples: ArraySlice<Float>) {
            var rest = samples[...]
            if !pending.isEmpty {
                let take = min(frameSize - pending.count, rest.count)
                pending.append(contentsOf: rest.prefix(take))
                rest = rest.dropFirst(take)
                guard pending.count == frameSize else { return }
                measure(pending[...])
                pending.removeAll(keepingCapacity: true)
            }
            while rest.count >= frameSize {
                measure(rest.prefix(frameSize))
                rest = rest.dropFirst(frameSize)
            }
            pending.append(contentsOf: rest)
        }

        /// 录音结束：最后不满一帧的部分也算一帧
        mutating func finish() {
            guard !pending.isEmpty else { return }
            measure(pending[...])
            pending.removeAll()
        }

        private mutating func measure(_ frame: ArraySlice<Float>) {
            var sum: Float = 0
            for v in frame { sum += v * v }
            let level = (sum / Float(frame.count)).squareRoot()
            peak = max(peak, level)
            frames += 1
            if level >= SpeechGate.voicedLevel {
                // 段内的短停顿算进这一段
                if run > 0 { run += gap }
                run += 1
                gap = 0
                longestRun = max(longestRun, run)
                lastVoicedFrameEnd = frames
            } else if run > 0 {
                gap += 1
                if gap > SpeechGate.hangoverFrames {
                    run = 0
                    gap = 0
                }
            }
        }

        var analysis: Analysis {
            Analysis(longestRunSeconds: Double(longestRun) * SpeechGate.frameSeconds, peakLevel: peak)
        }

        /// 已经录了多久（只算完整的帧）
        var elapsedSeconds: Double { Double(frames) * SpeechGate.frameSeconds }

        /// 最后一次有声音之后又过了多久
        var quietSeconds: Double { Double(frames - lastVoicedFrameEnd) * SpeechGate.frameSeconds }
    }

    /// 录音过程中该不该自动结束
    enum Watch: Equatable {
        case keepGoing
        /// 开头一直没有人声
        case noSpeech
        /// 说过话之后安静了很久
        case wentQuiet
    }

    /// 纯函数：根据目前录到的内容，判断录音该不该自动结束
    static func watch(_ tracker: Tracker) -> Watch {
        if !tracker.analysis.hasSpeech {
            return tracker.elapsedSeconds >= noSpeechTimeoutSeconds ? .noSpeech : .keepGoing
        }
        return tracker.quietSeconds >= trailingSilenceSeconds ? .wentQuiet : .keepGoing
    }

    /// 纯函数：录完后逐帧算音量，找出最长的连续有声段（忽略结尾的按键声）
    static func analyze(_ samples: [Float], sampleRate: Int = 16000) -> Analysis {
        let usable = max(0, samples.count - Int(tailIgnoredSeconds * Double(sampleRate)))
        var tracker = Tracker(sampleRate: sampleRate)
        tracker.feed(samples[..<usable])
        tracker.finish()
        return tracker.analysis
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
