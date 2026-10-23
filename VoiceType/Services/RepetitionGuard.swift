import Foundation

/// 识别结果的「重复折叠」。
///
/// 逐字生成的识别模型（Fun-ASR-Nano、Qwen3-ASR）和润色模型偶尔会陷入循环：
/// 在一处听不准的地方（如念出来的「⌥⌘V」）把同一小段反复输出到长度上限，
/// 2026-10-23 实测出现过上百个「CTRL、」。正常说话几乎不会把同一段连说 6 遍以上，
/// 所以这样的连续重复只留一份。
enum RepetitionGuard {
    /// 连续重复达到这个次数才算循环
    static let minRepeats = 6
    /// 只检查不超过这么长的重复单元
    static let maxUnitLength = 10
    /// 单个字的长串保留这么多个，「哈哈哈」这类不受影响
    static let singleCharacterKeep = 3

    /// 纯函数：把连续重复 minRepeats 次以上的片段折叠成一份（单个字留三个）。
    /// 纯数字不折叠，避免改坏「000000」这类验证码、号码。
    static func collapse(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            var collapsed = false
            for length in 1...maxUnitLength where i + length * minRepeats <= chars.count {
                let unit = chars[i..<(i + length)]
                var count = 1
                var next = i + length
                while next + length <= chars.count,
                    chars[next..<(next + length)].elementsEqual(unit)
                {
                    count += 1
                    next += length
                }
                guard count >= minRepeats, !unit.allSatisfy({ $0.isNumber }) else { continue }
                let keep = length == 1 ? singleCharacterKeep : 1
                for _ in 0..<keep { out.append(contentsOf: unit) }
                i = next
                collapsed = true
                break
            }
            if !collapsed {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }
}
