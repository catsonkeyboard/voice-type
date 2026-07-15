import Foundation

/// 一场会议的转写产物：与音频同名的 JSON 存于 meetings 目录
struct MeetingTranscript: Codable {
    var createdAt: Date
    var duration: Double
    var audioFile: String
    var segments: [SpeakerSegment]
    var speakerNames: [Int: String] = [:]
    var degraded: Bool = false  // 分离失败降级为整段转写

    static var meetingsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/meetings", isDirectory: true)
    }

    var speakerIds: [Int] {
        Array(Set(segments.map(\.speaker))).sorted()
    }

    func displayName(for speaker: Int) -> String {
        speakerNames[speaker] ?? "说话人\(speaker + 1)"
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func markdown() -> String {
        var lines = [
            "# 会议转写 \(createdAt.formatted(date: .abbreviated, time: .shortened))", "",
        ]
        if degraded {
            lines.append("> 说话人分离不可用，本稿为整段转写")
            lines.append("")
        }
        for seg in segments where !seg.text.isEmpty {
            lines.append(
                "**\(displayName(for: seg.speaker)) [\(Self.timestamp(seg.start))]** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url)
    }

    static func load(from url: URL) throws -> MeetingTranscript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingTranscript.self, from: Data(contentsOf: url))
    }
}

/// 会议纪要 prompt（走 PolishService 的通用补全通道）
enum MinutesPrompt {
    static let system = """
        你是会议纪要撰写助手。根据用户提供的带说话人标注的会议转写稿，输出结构化的中文会议纪要，包含以下小节（无相关内容的小节写"无"）：
        ## 会议主题
        ## 讨论要点
        ## 决议
        ## 待办事项
        要求：忠于原文，不编造；待办事项尽量标注负责人（依据说话人）；只输出纪要本身，不要解释。
        """

    static func user(transcript: MeetingTranscript) -> String {
        transcript.markdown()
    }
}
